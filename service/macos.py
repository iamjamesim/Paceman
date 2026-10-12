"""Local agent hook receiver for the macOS Paceman source.

The private Unix socket is reachable only through a user-owned directory. Hook
payloads are reduced to session/turn IDs and lifecycle states before storage.
"""
from __future__ import annotations

from collections import deque
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import socketserver
import stat
import threading
import time
import unicodedata

from service.claude import ClaudeSession
from service.claude_hooks import EVENTS as CLAUDE_EVENTS, validate_message
from service.codex_limits import read_codex_allowances
from service.usage import selected_reading, valid_reading
from service.session_titles import SessionTitles, read_session_titles
from service.codex_turns import read_codex_turn_metadata, read_codex_turn_statuses


EVENT_STATES = {
    "started": "idle", "working": "working", "needs-input": "needs_input",
    "question-opened": "needs_input",
    "completed": "finished", "interrupted": "idle", "ended": "idle",
}
ATTENTION_DELAY = 5.0
FINISHED_RETENTION = 10 * 60
TURN_STATUS_INTERVAL = 15.0
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,160}\Z")


class HookHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(1)
        try:
            raw = self.rfile.readline(4097)
            if len(raw) > 4096 or not raw.endswith(b"\n"):
                raise ValueError("Invalid hook event")
            changed = self.server.source.receive(json.loads(raw))
            response = {"ok": True, "changed": changed}
        except (ValueError, TypeError, TimeoutError):
            response = {"ok": False, "error": "invalid_event"}
        try:
            self.wfile.write(json.dumps(response).encode() + b"\n")
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass


class MacSource:
    def __init__(self, store, *, socket_path: Path, computer_name: str | None = None,
                 allowance_reader=read_codex_allowances,
                 turn_status_reader=read_codex_turn_statuses, monotonic=time.monotonic,
                 providers=("codex", "claude"), settings_reader=None,
                 turn_metadata_reader=read_codex_turn_metadata, title_reader=read_session_titles):
        self.store = store
        self.providers = tuple(p for p in providers if p in ("codex", "claude"))
        self.settings_reader = settings_reader
        self.usage_generation = 0
        self.socket_path = socket_path
        self.computer_name = (computer_name or socket.gethostname()).split(".")[0][:80]
        self.lock = threading.RLock()
        self.server = None
        self.thread = None
        self.socket_inode = None
        self.last_event_at = 0
        self.allowance_reader = allowance_reader
        self.allowance = None
        self.allowances = []
        self.allowance_thread = None
        self.next_allowance_at = 0.0
        self.turn_status_reader = turn_status_reader
        self.turn_status_thread = None
        self.next_turn_status_at = 0.0
        self.turn_metadata_reader = turn_metadata_reader
        self.turn_recovery_thread = None
        self.next_turn_recovery_at = 0.0
        self.pending_turn_events = {}
        # Raw Codex IDs are retained in memory only; published IDs stay hashed.
        self.turn_ids = {}
        self.confirmed_turns = {}
        self.closed = False
        self.titles = SessionTitles(self._titles_changed, reader=title_reader, monotonic=monotonic)
        self.monotonic = monotonic
        self.pending_attention = {}
        self.claude_sessions = {}
        self.last_event_by_provider = {}
        # Async questions outlive the tool call, but end with their turn.
        # A later user message can clear one while the turn is still running.
        self.pending_questions = {}
        self.published_questions = set()

    def __enter__(self):
        self.closed = False
        self.titles.start()
        self.socket_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        parent = self.socket_path.parent.stat()
        if parent.st_uid != os.getuid() or parent.st_mode & 0o077:
            raise ValueError("Hook socket directory must be private to this user")
        if self.socket_path.exists() or self.socket_path.is_symlink():
            info = self.socket_path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("Hook socket path is not an owned socket")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(.2)
                try:
                    client.connect(str(self.socket_path))
                except OSError as error:
                    if error.errno != errno.ECONNREFUSED:
                        raise
                else:
                    raise ValueError("Hook socket is already in use")
            if self.socket_path.lstat().st_ino != info.st_ino:
                raise ValueError("Hook socket changed during startup")
            self.socket_path.unlink()
        self.server = socketserver.UnixStreamServer(str(self.socket_path), HookHandler)
        self.socket_inode = self.socket_path.lstat().st_ino
        try:
            os.chmod(self.socket_path, 0o600)
            self.server.source = self
            with self.store.connect() as db:
                db.execute("CREATE TABLE IF NOT EXISTS mac_sessions (id TEXT PRIMARY KEY, "
                           "turn TEXT NOT NULL, state TEXT NOT NULL, updated REAL NOT NULL, "
                           "workspace_label TEXT)")
                if "workspace_label" not in {row[1] for row in db.execute("PRAGMA table_info(mac_sessions)")}:
                    db.execute("ALTER TABLE mac_sessions ADD COLUMN workspace_label TEXT")
                db.execute("INSERT OR REPLACE INTO metadata VALUES ('mode','macos')")
                previous_event = db.execute("SELECT value FROM metadata WHERE key='mac_last_agent_event_at'").fetchone()
                if previous_event:
                    previous_time = previous_event[0]
                else:
                    # Preserve evidence from installations that published an event
                    # before this metadata key existed.
                    try:
                        status = json.loads((self.socket_path.parent / "status.json").read_text())
                        previous_time = status.get("lastAgentEventAt", 0) if status.get("mode") == "macos" else 0
                    except (OSError, ValueError, AttributeError):
                        previous_time = 0
                try:
                    observed = float(previous_time)
                    self.last_event_at = observed if math.isfinite(observed) and observed > 0 else 0
                except (TypeError, ValueError):
                    self.last_event_at = 0
                if self.last_event_at:
                    db.execute("INSERT OR REPLACE INTO metadata VALUES ('mac_last_agent_event_at',?)",
                               (str(self.last_event_at),))
                for row in db.execute("SELECT key,value FROM metadata WHERE key LIKE 'mac_last_event_%'"):
                    provider = row["key"].removeprefix("mac_last_event_")
                    if provider in ("codex", "claude"):
                        try:
                            observed = float(row["value"])
                            if math.isfinite(observed) and observed > 0:
                                self.last_event_by_provider[provider] = observed
                        except (TypeError, ValueError):
                            pass
                db.execute("DELETE FROM schedule WHERE fired=0")
                # Hook IDs prove that a session emitted an event, not that it is
                # still open after this receiver was stopped. Start clean.
                db.execute("DELETE FROM mac_sessions")
            self.publish_current()
            self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=.05), daemon=True)
            self.thread.start()
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *_):
        with self.lock:
            self.closed = True
            self.titles.close()
        if self.thread is not None:
            self.server.shutdown()
            self.thread.join(timeout=2)
        if self.allowance_thread is not None:
            self.allowance_thread.join(timeout=2)
        if self.turn_status_thread is not None:
            self.turn_status_thread.join(timeout=2)
        if self.turn_recovery_thread is not None:
            self.turn_recovery_thread.join(timeout=2)
        if self.server is not None:
            self.server.server_close()
        try:
            if self.socket_path.lstat().st_ino == self.socket_inode:
                self.socket_path.unlink()
        except FileNotFoundError:
            pass

    def receive(self, command: dict) -> bool:
        if not isinstance(command, dict) or command.get("command") != "agent-event":
            raise ValueError("Unsupported command")
        provider = command.get("provider", "codex")
        if provider not in ("codex", "claude"):
            raise ValueError("Unsupported provider")
        if provider not in self.providers:
            return False
        session, turn, event = (command.get(key) for key in ("session", "turn", "event"))
        if (not isinstance(session, str) or not IDENTIFIER.fullmatch(session)
                or not isinstance(turn, str) or (turn and not IDENTIFIER.fullmatch(turn))
                or not isinstance(event, str)
                or event not in (EVENT_STATES if provider == "codex" else
                                 {*CLAUDE_EVENTS.values(), "question-opened", "interrupted"})):
            raise ValueError("Invalid event")
        workspace_label = command.get("workspaceLabel")
        if workspace_label is not None:
            if (not isinstance(workspace_label, str) or not 1 <= len(workspace_label) <= 40
                    or workspace_label != workspace_label.strip()
                    or "/" in workspace_label or "\\" in workspace_label
                    or any(unicodedata.category(char).startswith("C") for char in workspace_label)):
                workspace_label = None
        if provider == "claude":
            return self._receive_claude({**command, "workspaceLabel": workspace_label})
        key = hashlib.sha256(("codex:" + session).encode()).hexdigest()
        with self.lock, self.store.connect() as db:
            if "codex" not in self.providers:
                return False
            db.execute("BEGIN IMMEDIATE")
            if event != "ended":
                self.titles.track(key, "codex", session)
            previous = db.execute("SELECT * FROM mac_sessions WHERE id=?", (key,)).fetchone()
            if event == "ended":
                self.pending_turn_events.pop(key, None)
                pending = self.pending_attention.pop(key, None)
                question = self.pending_questions.pop(key, None)
                self.published_questions.discard(key)
                self.turn_ids.pop(key, None)
                self.confirmed_turns.pop(key, None)
                if previous is None and pending is None and question is None:
                    return False
                db.execute("DELETE FROM mac_sessions WHERE id=?", (key,))
            else:
                workspace_label = workspace_label or (previous["workspace_label"] if previous else None)
                # A late callback for an earlier turn must not overwrite the
                # current one. SessionStart has no turn and only registers once.
                if previous and event == "started":
                    return False
                if (previous and previous["turn"] and turn and previous["turn"] != turn
                        and command.get("hook") != "UserPromptSubmit"):
                    batch = self.pending_turn_events.get(key)
                    if batch is None:
                        batch = {"session": session, "previous": previous["turn"],
                                 "events": deque(maxlen=64)}
                        self.pending_turn_events[key] = batch
                        self.next_turn_recovery_at = 0.0
                    reduced = {"command": "agent-event", "session": session, "turn": turn,
                               "event": event, "hook": command.get("hook"),
                               "workspaceLabel": workspace_label}
                    if not batch["events"] or batch["events"][-1] != reduced:
                        batch["events"].append(reduced)
                    return False
                if command.get("hook") == "UserPromptSubmit":
                    self.pending_turn_events.pop(key, None)
                if turn:
                    self.turn_ids[key] = (session, turn)
                    if self.confirmed_turns.get(key) != turn:
                        self.confirmed_turns.pop(key, None)
                if (previous and previous["turn"] == turn and previous["state"] == "failed"
                        and self.confirmed_turns.get(key) == turn):
                    return False
                # Once a turn is terminal, no delayed nonterminal hook can
                # reopen it. A new prompt with a new turn ID remains valid.
                if (previous and previous["state"] in ("finished", "failed")
                        and (not turn or previous["turn"] == turn) and event != "completed"):
                    return False
                if event == "question-opened":
                    self.pending_questions[key] = (turn, self.monotonic() + ATTENTION_DELAY,
                                                   workspace_label)
                    self.published_questions.discard(key)
                    if previous is None:
                        db.execute("INSERT OR REPLACE INTO mac_sessions VALUES (?,?,?,?,?)",
                                   (key, turn, "working", time.time(), workspace_label))
                    self._record_event(db, "codex")
                    return False
                if event == "needs-input":
                    pending = self.pending_attention.get(key)
                    if (pending and pending[0] == turn) or (previous and previous["turn"] == turn
                            and previous["state"] == "needs_input"):
                        return False
                    self.pending_attention[key] = (turn, self.monotonic() + ATTENTION_DELAY,
                                                   workspace_label)
                    self._record_event(db, "codex")
                    return False
                self.pending_attention.pop(key, None)
                question_cleared = False
                if event == "completed" or command.get("hook") in ("UserPromptSubmit", "Interrupt"):
                    question_cleared = self.pending_questions.pop(key, None) is not None
                    self.published_questions.discard(key)
                if (previous and previous["turn"] == turn and previous["state"] == EVENT_STATES[event]
                        and previous["workspace_label"] == workspace_label and not question_cleared):
                    return False
                db.execute("INSERT OR REPLACE INTO mac_sessions VALUES (?,?,?,?,?)",
                           (key, turn, EVENT_STATES[event], time.time(), workspace_label))
            self._record_event(db, "codex")
            return self._publish(db)

    def _record_event(self, db, provider):
        self.last_event_at = time.time()
        self.last_event_by_provider[provider] = self.last_event_at
        db.execute("INSERT OR REPLACE INTO metadata VALUES ('mac_last_agent_event_at',?)",
                   (str(self.last_event_at),))
        db.execute("INSERT OR REPLACE INTO metadata VALUES (?,?)",
                   ("mac_last_event_" + provider, str(self.last_event_at)))

    def _receive_claude(self, command):
        validate_message(command)
        event = command["event"]
        remote_id = command.get("remoteSessionID")
        key = hashlib.sha256(("claude:" + command["session"]).encode()).hexdigest()
        with self.lock, self.store.connect() as db:
            if "claude" not in self.providers:
                return False
            db.execute("BEGIN IMMEDIATE")
            if event != "ended":
                self.titles.track(key, "claude", command["session"])
            previous = self.claude_sessions.get(key)
            if event == "ended":
                self.claude_sessions.pop(key, None)
            elif event == "started":
                if previous is None:
                    self.claude_sessions[key] = ClaudeSession(workspace_label=command.get("workspaceLabel"), remote_session_id=remote_id)
                elif "remoteSessionID" in command:
                    previous.remote_session_id = remote_id
            else:
                current = previous or ClaudeSession()
                if not current.receive(command, self.monotonic(), ATTENTION_DELAY):
                    return False
                self.claude_sessions[key] = current
            self._record_event(db, "claude")
            return self._publish(db)

    def _apply_settings(self):
        if self.settings_reader is None:
            return
        try:
            providers = tuple(self.settings_reader())
        except (OSError, ValueError):
            return
        if providers == self.providers:
            return
        if ("codex" in providers) != ("codex" in self.providers):
            self.usage_generation += 1
            self.next_allowance_at = 0
            if "codex" not in providers:
                self.allowance = None
                self.allowances = []
                self.pending_attention.clear()
                self.pending_questions.clear()
                self.published_questions.clear()
                self.turn_ids.clear()
                self.confirmed_turns.clear()
                self.pending_turn_events.clear()
                with self.store.connect() as db:
                    db.execute("DELETE FROM mac_sessions")
        if "claude" not in providers:
            self.claude_sessions.clear()
        self.providers = providers
        self.publish_current()

    def tick(self):
        # Hook lifecycle events own session state. Elapsed time alone is not
        # evidence that a working or waiting Codex conversation has ended.
        with self.lock:
            if self.closed:
                return
            self._apply_settings()
            now = self.monotonic()
            self.titles.refresh()
            if self.claude_sessions:
                retired_claude = [key for key, session in self.claude_sessions.items()
                                  if session.base_state in ("finished", "failed")
                                  and session.updated <= time.time() - FINISHED_RETENTION]
                for key in retired_claude:
                    del self.claude_sessions[key]
                # Publish only if a debounced attention state actually changed.
                with self.store.connect() as db:
                    db.execute("BEGIN IMMEDIATE")
                    self._publish(db, lifecycle_only=bool(retired_claude))
            due = [(key, pending) for key, pending in self.pending_attention.items()
                   if pending[1] <= now]
            if due:
                with self.store.connect() as db:
                    db.execute("BEGIN IMMEDIATE")
                    changed = False
                    for key, (turn, _, workspace_label) in due:
                        self.pending_attention.pop(key, None)
                        previous = db.execute("SELECT * FROM mac_sessions WHERE id=?", (key,)).fetchone()
                        if previous and previous["turn"] != turn:
                            continue
                        if previous and previous["state"] in ("needs_input", "finished", "failed"):
                            continue
                        db.execute("INSERT OR REPLACE INTO mac_sessions VALUES (?,?,?,?,?)",
                                   (key, turn, "needs_input", time.time(), workspace_label))
                        changed = True
                    if changed:
                        self._publish(db)
            newly_due = {key for key, (_, due, _) in self.pending_questions.items()
                         if due <= now and key not in self.published_questions}
            if newly_due:
                self.published_questions.update(newly_due)
                self.publish_current()
            if (self.pending_turn_events and now >= self.next_turn_recovery_at
                    and (self.turn_recovery_thread is None or not self.turn_recovery_thread.is_alive())):
                self.next_turn_recovery_at = now + TURN_STATUS_INTERVAL
                self.turn_recovery_thread = threading.Thread(
                    target=self._recover_turns, args=(list(self.pending_turn_events.items()),), daemon=True)
                self.turn_recovery_thread.start()
            if (now >= self.next_turn_status_at
                    and (self.turn_status_thread is None or not self.turn_status_thread.is_alive())):
                with self.store.connect() as db:
                    tracked = [(key, self.turn_ids[key]) for row in db.execute(
                        "SELECT id,turn FROM mac_sessions WHERE state IN ('working','needs_input','finished')")
                        if (key := row["id"]) in self.turn_ids
                        and self.confirmed_turns.get(key) != row["turn"]]
                if tracked:
                    self.next_turn_status_at = now + TURN_STATUS_INTERVAL
                    self.turn_status_thread = threading.Thread(
                        target=self._refresh_turn_statuses, args=(tracked,), daemon=True)
                    self.turn_status_thread.start()
            # Stop completes a turn, but some clients do not deliver SessionEnd.
            # Keep its result long enough to notice, then retire only that
            # finished display row. A later prompt creates it again.
            with self.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                retired = 0
                for row in db.execute("SELECT id FROM mac_sessions WHERE state IN ('finished','failed') AND updated<=?",
                                      (time.time() - FINISHED_RETENTION,)):
                    retired += db.execute("DELETE FROM mac_sessions WHERE id=?", (row["id"],)).rowcount
                    self.pending_questions.pop(row["id"], None)
                    self.published_questions.discard(row["id"])
                    self.turn_ids.pop(row["id"], None)
                    self.confirmed_turns.pop(row["id"], None)
                    self.pending_turn_events.pop(row["id"], None)
                if retired:
                    self._publish(db, lifecycle_only=True)
            if now >= self.next_allowance_at and "codex" in self.providers:
                if self.allowance_thread is None or not self.allowance_thread.is_alive():
                    self.next_allowance_at = now + 300
                    self.allowance_thread = threading.Thread(target=self._refresh_allowance,
                        args=(self.usage_generation,), daemon=True)
                    self.allowance_thread.start()

    def _refresh_allowance(self, generation=None):
        generation = self.usage_generation if generation is None else generation
        try:
            allowance = self.allowance_reader()
        except Exception:
            allowance = None
        with self.lock:
            if self.closed or "codex" not in self.providers or generation != self.usage_generation:
                return
            values = [allowance] if isinstance(allowance, dict) else allowance or []
            self.allowances = [v for v in values if valid_reading(v) and v["provider"] == "codex"]
            self.allowance = selected_reading(self.allowances)
            self.publish_current()

    def _recover_turns(self, tracked):
        """Promote only the newest saved turn; replay hooks in arrival order."""
        try:
            metadata = self.turn_metadata_reader([batch["session"] for _, batch in tracked])
        except Exception:
            return
        if not isinstance(metadata, dict):
            return
        with self.lock:
            if self.closed or "codex" not in self.providers:
                return
            for key, batch in tracked:
                if self.pending_turn_events.get(key) is not batch:
                    continue  # A prompt, session end or disable invalidated this read.
                rows = metadata.get(batch["session"])
                if not isinstance(rows, list) or not rows or not all(
                        isinstance(row, dict) and isinstance(row.get("id"), str) for row in rows):
                    continue
                latest = rows[0]["id"]
                events = [event for event in batch["events"] if event["turn"] == latest]
                if not events:
                    historical = {row["id"] for row in rows[1:]}
                    batch["events"] = deque((event for event in batch["events"]
                                              if event["turn"] not in historical), maxlen=64)
                    if not batch["events"]:
                        self.pending_turn_events.pop(key, None)
                    continue  # Unknown IDs may not have reached saved history yet.
                with self.store.connect() as db:
                    previous = db.execute("SELECT * FROM mac_sessions WHERE id=?", (key,)).fetchone()
                    if previous is None or previous["turn"] != batch["previous"]:
                        self.pending_turn_events.pop(key, None)
                        continue
                    label = events[0].get("workspaceLabel") or previous["workspace_label"]
                    db.execute("UPDATE mac_sessions SET turn=?,state='working',updated=?,workspace_label=? WHERE id=?",
                               (latest, time.time(), label, key))
                self.pending_turn_events.pop(key, None)
                self.pending_attention.pop(key, None)
                self.pending_questions.pop(key, None)
                self.published_questions.discard(key)
                self.confirmed_turns.pop(key, None)
                self.turn_ids[key] = (batch["session"], latest)
                known = {row["id"] for row in rows}
                remaining = deque((event for event in batch["events"]
                                   if event["turn"] not in known), maxlen=64)
                for event in events:
                    self.receive(event)
                self._refresh_turn_statuses([(key, (batch["session"], latest))],
                    outcomes={(batch["session"], latest): rows[0].get("status")})
                if remaining:
                    self.pending_turn_events[key] = {"session": batch["session"],
                                                     "previous": latest, "events": remaining}
                    self.next_turn_recovery_at = 0.0
                self.publish_current()

    def _refresh_turn_statuses(self, tracked, *, outcomes=None):
        if outcomes is None:
            try:
                outcomes = self.turn_status_reader([pair for _, pair in tracked])
            except Exception:
                return
        if not isinstance(outcomes, dict):
            return
        with self.lock, self.store.connect() as db:
            if self.closed:
                return
            db.execute("BEGIN IMMEDIATE")
            changed = False
            for key, pair in tracked:
                status = outcomes.get(pair)
                if status not in ("completed", "failed") or self.turn_ids.get(key) != pair:
                    continue
                row = db.execute("SELECT * FROM mac_sessions WHERE id=?", (key,)).fetchone()
                if row is None or row["turn"] != pair[1]:
                    continue
                self.confirmed_turns[key] = pair[1]
                state = "failed" if status == "failed" else "finished"
                self.pending_attention.pop(key, None)
                question_cleared = self.pending_questions.pop(key, None) is not None
                self.published_questions.discard(key)
                if row["state"] == state:
                    changed |= question_cleared
                    continue
                db.execute("UPDATE mac_sessions SET state=?,updated=? WHERE id=?",
                           (state, time.time(), key))
                changed = True
            if changed:
                self._publish(db)

    def _titles_changed(self):
        with self.lock:
            if not self.closed:
                self.publish_current()

    def publish_current(self):
        with self.lock, self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._publish(db)

    def _publish(self, db, *, lifecycle_only=False) -> bool:
        now_monotonic = self.monotonic()
        records = [{**dict(row), "provider": "codex"} for row in
                   db.execute("SELECT * FROM mac_sessions ORDER BY id")]
        records.extend({"id": key, "turn": item.turn, "state": item.state(now_monotonic),
                        "workspace_label": item.workspace_label, "remote_session_id": item.remote_session_id, "provider": "claude"}
                       for key, item in self.claude_sessions.items())
        records.sort(key=lambda row: row["id"])
        self.titles.retain(row["id"] for row in records)
        sessions = []
        for row in records:
            question = self.pending_questions.get(row["id"])
            # A completed or failed turn is authoritative even if a delayed
            # question marker survives an event path we did not anticipate.
            state = ("needs_input" if row["state"] not in ("finished", "failed")
                     and question and question[0] == row["turn"] and question[1] <= now_monotonic
                     else row["state"])
            session = {"id": row["id"], "provider": row["provider"], "state": state}
            if title := self.titles.name(row["id"]):
                session["name"] = title
            if row["workspace_label"]:
                session["workspaceLabel"] = row["workspace_label"]
            if row.get("remote_session_id"):
                session["remoteSessionID"] = row["remote_session_id"]
            sessions.append(session)
        state = next((candidate for candidate in ("needs_input", "failed", "working", "finished")
                      if any(session["state"] == candidate for session in sessions)), "idle")
        activity_key = json.dumps([(row["id"], row["turn"], session["state"])
                                   for row, session in zip(records, sessions)])
        old_key = db.execute("SELECT value FROM metadata WHERE key='activity_key'").fetchone()
        last = db.execute("SELECT * FROM events ORDER BY seq DESC LIMIT 1").fetchone()
        old = json.loads(last["payload"]) if last["payload"] else {}
        payload = {"sourceName": self.computer_name, "state": state,
                   "sessions": sessions, "allowance": self.allowance,
                   "allowances": self.allowances, "configuredProviders": list(self.providers)}
        if old_key and old_key[0] == activity_key and all(old.get(k) == v for k, v in payload.items()):
            return False
        changed = not old_key or old_key[0] != activity_key
        activity_changed = changed and (not lifecycle_only or old.get("state") != state)
        now = time.time()
        seq = db.execute("INSERT INTO events(at,state,label,kind) VALUES (?,?,?,?)",
                         (now, state, "Mac activity", "activity" if activity_changed else "presentation")).lastrowid
        payload["eventID"] = str(seq) if activity_changed else old["eventID"]
        payload["changedAt"] = now if activity_changed else old["changedAt"]
        db.execute("UPDATE events SET payload=? WHERE seq=?", (json.dumps(payload, separators=(",", ":")), seq))
        db.execute("INSERT OR REPLACE INTO metadata VALUES ('activity_key',?)", (activity_key,))
        return True
