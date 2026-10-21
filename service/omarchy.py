"""Omarchy event receiver without Bluetooth ownership.

Accepts Paceman's Codex and Claude hooks and the older omarchy-watch-codex protocol. Only
opaque IDs and lifecycle states are retained from hooks; explicit provider
titles are read separately. Hook arguments and conversation content are ignored.
"""
from __future__ import annotations

from dataclasses import asdict
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import stat
import struct
import threading
import time

from service.allowance import allowance_snapshots
from service.codex_turns import read_codex_turn_metadata
from service.usage import readings, selected_reading
from service.claude import ClaudeSession
from service.native_attention import PendingDecisions, native_waiting, native_empty
from service.claude_hooks import validate_message
from service.session_titles import SessionTitles, read_session_titles
from service.processes import AgentProcesses, ProcessIdentity

MAX_AGE = 24 * 60 * 60
FINISHED_RETENTION = 10 * 60
ATTENTION_DELAY = 5.0
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,160}\Z")
EVENTS = {"working": "working", "needs-input": "needs_input", "completed": "finished",
          "interrupted": "idle", "ended": "idle"}


def default_socket() -> Path:
    return Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "omarchy-watch.sock"


class EventHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(.25)
        try:
            peer_pid = None
            if hasattr(socket, "SO_PEERCRED"):
                peer_pid, uid, _ = struct.unpack("3i", self.connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if uid != os.getuid():
                    return
            raw = self.rfile.readline(4097)
            if len(raw) > 4096 or not raw.endswith(b"\n"):
                raise ValueError("Invalid event")
            changed = self.server.source.receive(json.loads(raw), peer_pid=peer_pid)
            response = {"ok": True, "changed": changed}
        except (ValueError, TypeError, TimeoutError):
            response = {"ok": False, "error": "invalid_event"}
        try:
            self.wfile.write(json.dumps(response).encode() + b"\n")
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass


class OmarchySource:
    def __init__(self, store, *, socket_path: Path | None = None, state_dir: Path | None = None,
                 processes=None, computer_name: str | None = None, monotonic=time.monotonic, providers=("codex",), settings_reader=None, title_reader=read_session_titles,
                 turn_metadata_reader=read_codex_turn_metadata):
        self.providers = tuple(providers)
        self.settings_reader = settings_reader
        self.last_event_by_provider = {}
        self.store = store
        self.socket_path = socket_path or default_socket()
        self.state_dir = state_dir or Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy"
        self.lock = threading.RLock()
        self.closed = False
        self.titles = SessionTitles(self._titles_changed, reader=title_reader, monotonic=monotonic)
        self.next_poll = 0.0
        self.server = None
        self.thread = None
        self.socket_inode = None
        self.last_event_at = 0
        self.pending_questions = {}
        self.native_turns = {}
        self.session_refs = {}
        self.native_attention = {}
        self.pending_turn_events = {}
        self.confirmed_turns = {}
        self.turn_metadata_reader = turn_metadata_reader
        self.recovery_thread = None
        self.next_recovery_at = 0.0
        self.monotonic = monotonic
        self.processes = processes if processes is not None else AgentProcesses()
        self.computer_name = (computer_name or socket.gethostname()).split(".")[0][:80] or "Computer"

    def __enter__(self):
        self.closed = False
        self.titles.start()
        # Never steal a live desktop socket or remove an unrelated filesystem entry.
        self.socket_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.socket_path.exists() or self.socket_path.is_symlink():
            info = self.socket_path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("Agent socket path is not an owned socket")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(.2)
                try:
                    client.connect(str(self.socket_path))
                except OSError as error:
                    if error.errno != errno.ECONNREFUSED:
                        raise
                else:
                    raise ValueError("Agent socket is in use; stop the desktop bridge or choose --agent-socket")
            if self.socket_path.lstat().st_ino != info.st_ino:
                raise ValueError("Agent socket changed during startup")
            self.socket_path.unlink()
        self.server = socketserver.UnixStreamServer(str(self.socket_path), EventHandler)
        self.socket_inode = self.socket_path.lstat().st_ino
        try:
            os.chmod(self.socket_path, 0o600)
            self.server.source = self
            with self.store.connect() as db:
                db.execute("CREATE TABLE IF NOT EXISTS omarchy_sessions (id TEXT PRIMARY KEY, "
                           "provider TEXT NOT NULL, turn TEXT NOT NULL, state TEXT NOT NULL, updated REAL NOT NULL)")
                db.execute("CREATE TABLE IF NOT EXISTS omarchy_processes (session_id TEXT PRIMARY KEY, "
                           "pid INTEGER NOT NULL, start_ticks TEXT NOT NULL, boot_id TEXT NOT NULL, "
                           "closed INTEGER NOT NULL DEFAULT 0)")
                db.execute("CREATE TABLE IF NOT EXISTS omarchy_claude (id TEXT PRIMARY KEY, lifecycle TEXT NOT NULL)")
                db.execute("CREATE TABLE IF NOT EXISTS omarchy_tracking (id TEXT PRIMARY KEY, session TEXT NOT NULL, "
                           "native_turn TEXT, question_turn TEXT, question_due REAL, attention_turn TEXT, waiting INTEGER)")
                for row in db.execute("SELECT t.* FROM omarchy_tracking t JOIN omarchy_processes p "
                                      "ON p.session_id=t.id WHERE p.closed=0"):
                    key = row["id"]
                    self.session_refs[key] = row["session"]
                    if row["native_turn"]:
                        self.native_turns[key] = row["native_turn"]
                    if row["question_turn"]:
                        self.pending_questions[key] = row["question_turn"], row["question_due"]
                    if row["waiting"] is not None:
                        self.native_attention[key] = row["attention_turn"], bool(row["waiting"])
                for row in db.execute("SELECT key,value FROM metadata WHERE key LIKE 'omarchy_last_event_%'"):
                    self.last_event_by_provider[row["key"].removeprefix("omarchy_last_event_")] = float(row["value"])
                # Native Claude identities are RAM-only; do not restore an
                # aggregate that checkpoints cannot reconcile exactly.
                for row in db.execute('SELECT id FROM omarchy_claude'):
                    self.native_attention.pop(row['id'], None)
                self.last_event_at = max(self.last_event_by_provider.values(), default=0)
                db.execute("INSERT OR REPLACE INTO metadata VALUES ('mode','omarchy')")
                db.execute("DELETE FROM schedule WHERE fired=0")
                # Legacy records cannot establish ownership. A new hook registers
                # them; don't carry old anonymous completions into the live list.
                db.execute("UPDATE omarchy_sessions SET state='idle' WHERE id NOT IN "
                           "(SELECT session_id FROM omarchy_processes)")
                for row in db.execute("SELECT id,provider FROM omarchy_sessions"):
                    if row['id'] in self.session_refs:
                        self.titles.track(row['id'], row['provider'], self.session_refs[row['id']])
            self.tick(force=True)
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
        if self.recovery_thread is not None:
            self.recovery_thread.join(timeout=2)
        if self.thread is not None:
            self.server.shutdown()
            self.thread.join(timeout=2)
        if self.server is not None:
            self.server.server_close()
        try:
            if self.socket_path.lstat().st_ino == self.socket_inode:
                self.socket_path.unlink()
        except FileNotFoundError:
            pass

    def receive(self, command: dict, *, peer_pid=None) -> bool:
        if not isinstance(command, dict) or command.get("command") != "agent-event":
            raise ValueError("Unsupported command")
        if command.get("provider") == "claude":
            return self.receive_claude(command, peer_pid)
        source, session, turn = (command.get(key) for key in ("source", "session", "turn"))
        event = command.get("event")
        async_question = event == "needs-input" and command.get("attention") == "async"
        native = command.get("adapter") == "paceman"
        if (not all(isinstance(value, str) and IDENTIFIER.fullmatch(value) for value in (source, session))
                or not isinstance(event, str) or event not in EVENTS
                or not isinstance(turn, str)
                or not (IDENTIFIER.fullmatch(turn) or (turn == "" and event in ("ended", "interrupted")))):
            raise ValueError("Invalid event")
        # Namespaced opaque keys keep session IDs out of the phone's presentation.
        key = hashlib.sha256(f"{source}:{session}".encode()).hexdigest()
        owner = self.processes.identify(peer_pid) if source == "codex" else None
        if owner is None:
            # Neither a claimed PID in the payload nor a random local client is
            # evidence of a live agent session. Keep the protocol best-effort.
            return False
        with self.lock, self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self.apply_settings(db)
            self.prune_processes(db)
            if "codex" not in self.providers:
                return self.publish(db, lifecycle_only=True)
            previous = db.execute("SELECT * FROM omarchy_sessions WHERE id=?", (key,)).fetchone()
            binding = db.execute("SELECT * FROM omarchy_processes WHERE session_id=?", (key,)).fetchone()
            same_owner = binding is not None and self.identity(binding) == owner
            if (binding is not None and not same_owner
                    and (not binding["closed"] or event != "working" or previous["turn"] == turn)):
                # A late event from another still-live process cannot take over
                # an already registered session.
                return self.publish(db, lifecycle_only=True)
            if binding is not None and not same_owner:
                self.pending_questions.pop(key, None)
                self.native_turns.pop(key, None)
                self.native_attention.pop(key, None)
                self.pending_turn_events.pop(key, None)
            if not turn:
                if previous is None:
                    return self.publish(db, lifecycle_only=True)
                turn = previous["turn"]
            # During migration both plugins can fire for one Codex turn. Once
            # Paceman has observed that turn, older nonterminal companion hooks
            # cannot clear its pending question or reorder its lifecycle.
            if (not native and event in ("working", "needs-input")
                    and self.native_turns.get(key) == turn):
                return self.publish(db, lifecycle_only=True)
            if ((binding is None or binding["closed"]) and event != "ended"
                    and db.execute("SELECT COUNT(*) FROM omarchy_processes WHERE closed=0 AND NOT "
                                   "(pid=? AND start_ticks=? AND boot_id=?)",
                                   (owner.pid, owner.start_ticks, owner.boot_id)).fetchone()[0] >= 100):
                raise ValueError("Too many active sessions")
            if previous:
                if same_owner and previous["turn"] != turn and (
                        event != "working" or native and command.get("hook") != "UserPromptSubmit"):
                    if native and event not in ("ended", "interrupted"):
                        batch = self.pending_turn_events.setdefault(key, {
                            "session": session, "previous": previous["turn"], "owner": owner, "events": []})
                        event_data = {field: command[field] for field in (
                            "command", "source", "adapter", "session", "turn", "event", "hook", "attention")
                            if field in command}
                        batch["events"] = (batch["events"] + [event_data])[-64:]
                        self.next_recovery_at = 0.0
                    return self.publish(db, lifecycle_only=True)
                if previous["turn"] != turn:
                    self.pending_questions.pop(key, None)
                    self.pending_turn_events.pop(key, None)
                    self.confirmed_turns.pop(key, None)
                if previous["turn"] == turn:
                    if same_owner and (binding["closed"] or (previous["state"] == "idle" and event != "ended")):
                        return self.publish(db, lifecycle_only=True)
                    if same_owner and previous["state"] == "failed" and event != "ended":
                        return self.publish(db, lifecycle_only=True)
                    if (same_owner and previous["state"] == EVENTS[event]
                            and event != "ended" and not async_question
                            and command.get("hook") != "UserPromptSubmit"):
                        if native:
                            self.native_turns[key] = turn
                        self.session_refs[key] = session
                        return self.publish(db, lifecycle_only=True)
                    if same_owner and previous["state"] in ("idle", "finished", "failed") and event in ("working", "needs-input"):
                        return self.publish(db, lifecycle_only=True)
            # A CLI can switch/resume conversations within one process. Its
            # latest session replaces its old binding instead of counting twice.
            replaced = db.execute("SELECT session_id FROM omarchy_processes WHERE pid=? AND "
                                  "start_ticks=? AND boot_id=? AND session_id!=?",
                                  (owner.pid, owner.start_ticks, owner.boot_id, key)).fetchall()
            for row in replaced:
                db.execute("UPDATE omarchy_sessions SET state='idle' WHERE id=?", (row[0],))
                db.execute("UPDATE omarchy_processes SET closed=1 WHERE session_id=?", (row[0],))
                self.pending_questions.pop(row[0], None)
                self.native_turns.pop(row[0], None)
            self.session_refs[key] = session
            if native:
                self.native_turns[key] = turn
            if async_question:
                if key not in self.pending_questions or self.pending_questions[key][0] != turn:
                    self.pending_questions[key] = (turn, self.monotonic() + ATTENTION_DELAY)
            elif event in ("completed", "interrupted", "ended") or command.get("hook") == "UserPromptSubmit":
                self.pending_questions.pop(key, None)
            if event in ("completed", "interrupted", "ended"):
                if event == 'ended':
                    self.native_attention.pop(key, None)
                self.pending_turn_events.pop(key, None)
            state = (previous["state"] if async_question and previous and previous["turn"] == turn
                     else "working" if async_question else EVENTS[event])
            db.execute("INSERT OR REPLACE INTO omarchy_processes VALUES (?,?,?,?,0)",
                       (key, owner.pid, owner.start_ticks, owner.boot_id))
            db.execute("INSERT OR REPLACE INTO omarchy_sessions VALUES (?,?,?,?,?)",
                       (key, source, turn, state, time.time()))
            self.titles.track(key, "codex", session)
            self.record_event(db, "codex")
            if event == "ended":
                db.execute("UPDATE omarchy_processes SET closed=1 WHERE session_id=?", (key,))
                self.native_turns.pop(key, None)
            return self.publish(db, lifecycle_only=event == "ended")

    def record_event(self, db, provider):
        self.last_event_at = time.time()
        self.last_event_by_provider[provider] = self.last_event_at
        db.execute("INSERT OR REPLACE INTO metadata VALUES (?,?)",
                   ("omarchy_last_event_" + provider, str(self.last_event_at)))

    def apply_settings(self, db):
        if self.settings_reader is not None:
            try:
                providers = tuple(self.settings_reader())
            except (OSError, ValueError):
                return  # Atomic controls normally prevent this; keep other agents running.
            if any(p not in ("codex", "claude") for p in providers):
                raise ValueError("Unknown agent provider")
            self.providers = providers
        for row in db.execute("SELECT id,provider FROM omarchy_sessions").fetchall():
            if row["provider"] not in self.providers:
                db.execute("DELETE FROM omarchy_processes WHERE session_id=?", (row["id"],))
                db.execute("DELETE FROM omarchy_sessions WHERE id=?", (row["id"],))
                db.execute("DELETE FROM omarchy_claude WHERE id=?", (row["id"],))
                self.pending_questions.pop(row["id"], None)
                self.native_turns.pop(row["id"], None)

    def receive_claude(self, command, peer_pid):
        session, turn = command.get("session"), command.get("turn")
        if (not isinstance(session, str) or not IDENTIFIER.fullmatch(session)
                or not isinstance(turn, str) or (turn and not IDENTIFIER.fullmatch(turn))):
            raise ValueError("Invalid Claude identity")
        validate_message(command)
        owner = self.processes.identify(peer_pid, provider="claude")
        if owner is None:
            return False
        key = hashlib.sha256(("claude:" + session).encode()).hexdigest()
        event, hook = command["event"], command["hook"]
        with self.lock, self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self.apply_settings(db)
            self.prune_processes(db)
            if "claude" not in self.providers:
                return self.publish(db, lifecycle_only=True)
            previous = db.execute("SELECT * FROM omarchy_sessions WHERE id=?", (key,)).fetchone()
            binding = db.execute("SELECT * FROM omarchy_processes WHERE session_id=?", (key,)).fetchone()
            if binding is not None:
                same_owner = self.identity(binding) == owner
                if ((not same_owner and not binding["closed"]) or
                        (binding["closed"] and (hook != "UserPromptSubmit" or previous["turn"] == turn))):
                    return self.publish(db, lifecycle_only=True)
            if binding is None or binding["closed"]:
                if db.execute("SELECT COUNT(*) FROM omarchy_processes WHERE closed=0 AND NOT "
                              "(pid=? AND start_ticks=? AND boot_id=?)",
                              (owner.pid, owner.start_ticks, owner.boot_id)).fetchone()[0] >= 100:
                    raise ValueError("Too many active sessions")
                current = ClaudeSession()
            else:
                saved = db.execute("SELECT lifecycle FROM omarchy_claude WHERE id=?", (key,)).fetchone()
                current = ClaudeSession(**json.loads(saved[0])) if saved else ClaudeSession()
            previous_remote = current.remote_session_id
            native = self.native_attention.get(key)
            input_resolved = False
            if (command.get('hook') == 'ElicitationResult' and isinstance(native, PendingDecisions)
                    and native.owner == current.remote_session_id):
                updated = native.resolve_input(command['inputID'])
                input_resolved = updated != native
                self.native_attention[key] = updated
                if input_resolved and not updated and current.base_state in ('finished', 'failed'):
                    current.updated = time.time()
            if event == "started":
                if "remoteSessionID" in command:
                    current.remote_session_id = command["remoteSessionID"]
            elif event == "ended":
                if binding is None:
                    return self.publish(db, lifecycle_only=True)
                if turn and current.turn and turn != current.turn:
                    return self.publish(db, lifecycle_only=True)
                current.base_state = "idle"
                current.remote_session_id = None
                current.waits.clear()
                current.tools.clear()
            elif not current.receive({**command, "workspaceLabel": None}, self.monotonic(), ATTENTION_DELAY) and not input_resolved:
                return self.publish(db, lifecycle_only=True)
            if previous_remote and current.remote_session_id != previous_remote:
                self.native_attention.pop(key, None)
            # Linux monotonic time is shared across processes within a boot.
            # Ownership reconciliation rejects records from earlier boots.
            if any(len(values) > 128 for values in (current.waits, current.tools, current.child_waits, current.child_tools)):
                raise ValueError("Too many pending Claude tools")
            for row in db.execute("SELECT session_id FROM omarchy_processes WHERE pid=? AND "
                                  "start_ticks=? AND boot_id=? AND session_id!=?",
                                  (owner.pid, owner.start_ticks, owner.boot_id, key)).fetchall():
                db.execute("UPDATE omarchy_sessions SET state='idle' WHERE id=?", (row[0],))
                db.execute("UPDATE omarchy_processes SET closed=1 WHERE session_id=?", (row[0],))
                db.execute("DELETE FROM omarchy_claude WHERE id=?", (row[0],))
            db.execute("INSERT OR REPLACE INTO omarchy_processes VALUES (?,?,?,?,?)",
                       (key, owner.pid, owner.start_ticks, owner.boot_id, int(event == "ended")))
            db.execute("INSERT OR REPLACE INTO omarchy_sessions VALUES (?,?,?,?,?)",
                       (key, "claude", current.turn, current.base_state, current.updated))
            db.execute("INSERT OR REPLACE INTO omarchy_claude VALUES (?,?)",
                       (key, json.dumps(asdict(current), separators=(",", ":"))))
            self.session_refs[key] = session
            self.titles.track(key, "claude", session)
            self.record_event(db, "claude")
            return self.publish(db, lifecycle_only=event in ("started", "ended"))

    @staticmethod
    def identity(row):
        return ProcessIdentity(row["pid"], row["start_ticks"], row["boot_id"])

    def _tracking_maps(self):
        return (self.session_refs, self.native_turns, self.pending_questions,
                self.native_attention, self.pending_turn_events, self.confirmed_turns)

    def _persist_tracking(self, db):
        # Restore only while the same kernel-verified owner is still alive.
        # Monotonic deadlines are valid within that owner's Linux boot.
        live = {row[0] for row in db.execute("SELECT session_id FROM omarchy_processes WHERE closed=0")}
        for mapping in self._tracking_maps():
            for key in mapping.keys() - live:
                mapping.pop(key, None)
        db.execute("DELETE FROM omarchy_tracking WHERE id NOT IN "
                   "(SELECT session_id FROM omarchy_processes WHERE closed=0)")
        for key, session in self.session_refs.items():
            question = self.pending_questions.get(key, (None, None))
            attention = self.native_attention.get(key, (None, None))
            if isinstance(attention, PendingDecisions):
                current = db.execute('SELECT turn,provider FROM omarchy_sessions WHERE id=?', (key,)).fetchone()
                turn = current['turn'] if current else ''
                scope = None if any(identity[0] is None for identity in attention.requests) else turn
                waiting = native_waiting(attention, turn)
                attention = ((None, None) if current and current['provider'] == 'claude' and not waiting
                             else (scope, waiting))
            db.execute("INSERT OR REPLACE INTO omarchy_tracking VALUES (?,?,?,?,?,?,?)",
                       (key, session, self.native_turns.get(key), *question, *attention))

    def native_requests_changed(self, session, by_turn):
        key = hashlib.sha256(("codex:" + session).encode()).hexdigest()
        with self.lock, self.store.connect() as db:
            turn = self.native_response_sessions().get(session)
            if turn is None:
                return
            if by_turn is None:
                return
            previous = native_waiting(self.native_attention.get(key), turn)
            if isinstance(by_turn, PendingDecisions):
                self.native_attention[key] = by_turn
            elif turn in by_turn:
                self.native_attention[key] = turn, bool(by_turn[turn])
            if previous and not native_waiting(self.native_attention.get(key), turn):
                db.execute("UPDATE omarchy_sessions SET updated=? WHERE id=? AND state IN ('finished','failed')",
                           (time.time(), key))
            self.publish(db)

    def native_response_sessions(self):
        with self.lock, self.store.connect() as db:
            if self.closed or 'codex' not in self.providers:
                return {}
            return {self.session_refs[row['id']]: row['turn'] for row in db.execute(
                "SELECT s.*,p.pid,p.start_ticks,p.boot_id FROM omarchy_sessions s "
                "JOIN omarchy_processes p ON p.session_id=s.id WHERE p.closed=0 AND s.provider='codex'")
                if row['id'] in self.session_refs and self.processes.is_alive(self.identity(row))}

    def native_claude_sessions(self):
        with self.lock, self.store.connect() as db:
            if self.closed or "claude" not in self.providers:
                return []
            result = []
            for row in db.execute("SELECT c.*,p.pid,p.start_ticks,p.boot_id FROM omarchy_claude c "
                                  "JOIN omarchy_processes p ON p.session_id=c.id WHERE p.closed=0"):
                current = ClaudeSession(**json.loads(row['lifecycle']))
                if (current.remote_session_id and current.turn
                        and (current.base_state not in ('finished', 'failed') or current.updated > time.time() - FINISHED_RETENTION
                             or current.child_waits or native_waiting(self.native_attention.get(row['id']), current.turn))
                        and self.processes.is_alive(self.identity(row))):
                    result.append((row['id'], current.remote_session_id, current.turn))
            return result

    def native_claude_requests_changed(self, session, turn, waiting):
        with self.lock, self.store.connect() as db:
            if not any(key == session and active == turn for key, _, active in self.native_claude_sessions()):
                return
            if waiting is None:
                return
            row = db.execute('SELECT lifecycle FROM omarchy_claude WHERE id=?', (session,)).fetchone()
            current = ClaudeSession(**json.loads(row[0]))
            if isinstance(waiting, PendingDecisions) and waiting.owner != current.remote_session_id:
                return
            previous = native_waiting(self.native_attention.get(session), turn)
            if isinstance(waiting, PendingDecisions):
                self.native_attention[session] = waiting.merge(self.native_attention.get(session))
            elif waiting:
                self.native_attention[session] = turn, True
            else:
                self.native_attention.pop(session, None)
            if previous and not native_waiting(self.native_attention.get(session), turn) and current.base_state in ('finished', 'failed'):
                current.updated = time.time()
                db.execute('UPDATE omarchy_sessions SET updated=? WHERE id=?', (current.updated, session))
                db.execute('UPDATE omarchy_claude SET lifecycle=? WHERE id=?',
                    (json.dumps(asdict(current), separators=(',', ':')), session))
            self.publish(db)

    def native_claude_owner(self, session, remote):
        with self.lock, self.store.connect() as db:
            row = db.execute('SELECT p.*,c.lifecycle FROM omarchy_processes p JOIN omarchy_claude c '
                             'ON c.id=p.session_id WHERE p.session_id=? AND p.closed=0', (session,)).fetchone()
            if row and json.loads(row['lifecycle']).get('remote_session_id') == remote:
                owner = self.identity(row)
                return owner if self.processes.is_alive(owner) else None

    def native_claude_requests_resolved(self, session, turn, tools, pending_tools):
        with self.lock, self.store.connect() as db:
            if not any(key == session and active == turn for key, _, active in self.native_claude_sessions()):
                return
            row = db.execute("SELECT lifecycle FROM omarchy_claude WHERE id=?", (session,)).fetchone()
            current = ClaudeSession(**json.loads(row[0]))
            current.resolve_tools(tools, pending_tools)
            db.execute("UPDATE omarchy_claude SET lifecycle=? WHERE id=?",
                       (json.dumps(asdict(current), separators=(",", ":")), session))
            self.publish(db)

    def _recover_turns(self, tracked, batches):
        refs = {row['id']: self.session_refs.get(row['id']) for row, _ in tracked}
        try:
            metadata = self.turn_metadata_reader(list(dict.fromkeys(
                [ref for ref in refs.values() if ref] + [b['session'] for b in batches.values()])))
        except Exception:
            return
        if not isinstance(metadata, dict):
            return
        with self.lock:
            if self.closed or "codex" not in self.providers:
                return
            for key, batch in batches.items():
                if self.pending_turn_events.get(key) is not batch or not self.processes.is_alive(batch['owner']):
                    continue
                rows = metadata.get(batch['session'])
                if not isinstance(rows, list) or not rows or not all(
                        isinstance(row, dict) and isinstance(row.get('id'), str) for row in rows):
                    continue
                latest = rows[0].get('id')
                events = [event for event in batch['events'] if event['turn'] == latest]
                if not events:
                    historical = {row.get('id') for row in rows[1:] if isinstance(row, dict)}
                    batch['events'] = [event for event in batch['events'] if event['turn'] not in historical]
                    if not batch['events']:
                        self.pending_turn_events.pop(key, None)
                    continue
                with self.store.connect() as db:
                    current = db.execute("SELECT s.turn,p.* FROM omarchy_sessions s JOIN omarchy_processes p "
                                         "ON p.session_id=s.id WHERE s.id=?", (key,)).fetchone()
                    if (not current or current['closed'] or current['turn'] != batch['previous']
                            or self.identity(current) != batch['owner']):
                        continue
                    db.execute("UPDATE omarchy_sessions SET turn=?,state='working',updated=? WHERE id=?",
                               (latest, time.time(), key))
                self.pending_turn_events.pop(key, None)
                self.pending_questions.pop(key, None)
                self.confirmed_turns.pop(key, None)
                known = {row['id'] for row in rows}
                remaining = [event for event in batch['events'] if event['turn'] not in known]
                for event in events:
                    self.receive(event, peer_pid=batch['owner'].pid)
                if remaining:
                    # Hooks arriving during the read may describe a newer turn
                    # that has not reached saved metadata. Verify them again
                    # against the turn we just recovered, preserving order.
                    self.pending_turn_events[key] = dict(session=batch['session'], previous=latest,
                        owner=batch['owner'], events=remaining)
                    self.next_recovery_at = 0.0
                tracked.append(({'id': key, 'turn': latest}, batch['owner']))
                refs[key] = batch['session']
            with self.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                for row, owner in tracked:
                    outcomes = metadata.get(refs.get(row['id']), [])
                    status = next((r.get('status') for r in outcomes if isinstance(r, dict)
                                   and r.get('id') == row['turn']), None) if isinstance(outcomes, list) else None
                    if status not in ('completed', 'failed') or not self.processes.is_alive(owner):
                        continue  # Interrupted from a separate reader is not authoritative.
                    current = db.execute("SELECT s.turn,p.* FROM omarchy_sessions s JOIN omarchy_processes p "
                                         "ON p.session_id=s.id WHERE s.id=?", (row['id'],)).fetchone()
                    if (not current or current['closed'] or current['turn'] != row['turn']
                            or self.identity(current) != owner):
                        continue
                    db.execute("UPDATE omarchy_sessions SET state=?,updated=? WHERE id=? AND state!=?",
                               ('failed' if status == 'failed' else 'finished', time.time(), row['id'],
                                'failed' if status == 'failed' else 'finished'))
                    self.confirmed_turns[row['id']] = row['turn']
                    self.pending_questions.pop(row['id'], None)
                self.publish(db, lifecycle_only=True)

    def prune_processes(self, db):
        for row in db.execute("SELECT * FROM omarchy_processes").fetchall():
            if not self.processes.is_alive(self.identity(row)):
                db.execute("UPDATE omarchy_sessions SET state='idle' WHERE id=?", (row["session_id"],))
                db.execute("DELETE FROM omarchy_processes WHERE session_id=?", (row["session_id"],))
                db.execute("DELETE FROM omarchy_claude WHERE id=?", (row["session_id"],))
                db.execute("DELETE FROM omarchy_tracking WHERE id=?", (row["session_id"],))
                # Clear before a hook can register a replacement owner under
                # the same session key, even when the turn ID is unchanged.
                for mapping in self._tracking_maps():
                    mapping.pop(row["session_id"], None)

    def tick(self, *, force=False):
        with self.lock:
            if self.closed:
                return
            self.titles.refresh()
            if not force and self.monotonic() < self.next_poll:
                return
            with self.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                self.apply_settings(db)
                self.prune_processes(db)
                # Keep verified process bindings even after a completed turn
                # disappears from the display; a new turn can use the binding.
                cutoff = time.time() - MAX_AGE
                db.execute("DELETE FROM omarchy_processes WHERE closed=1 AND session_id IN "
                           "(SELECT id FROM omarchy_sessions WHERE updated<?)", (cutoff,))
                db.execute("DELETE FROM omarchy_sessions WHERE updated<? AND id NOT IN "
                           "(SELECT session_id FROM omarchy_processes)", (cutoff,))
                db.execute("DELETE FROM omarchy_claude WHERE id NOT IN (SELECT id FROM omarchy_sessions)")
                self.publish(db, lifecycle_only=True)
                tracked = [(dict(row), self.identity(row)) for row in db.execute(
                    "SELECT s.*,p.pid,p.start_ticks,p.boot_id FROM omarchy_sessions s "
                    "JOIN omarchy_processes p ON p.session_id=s.id "
                    "WHERE p.closed=0 AND s.provider='codex' AND (s.state IN ('working','needs_input') "
                    "OR (s.state='finished' AND s.updated>?))", (time.time() - FINISHED_RETENTION,))
                    if self.confirmed_turns.get(row['id']) != row['turn']]
            if (tracked or self.pending_turn_events) and self.monotonic() >= self.next_recovery_at and (
                    self.recovery_thread is None or not self.recovery_thread.is_alive()):
                self.next_recovery_at = self.monotonic() + 5
                self.recovery_thread = threading.Thread(target=self._recover_turns,
                    args=(tracked, dict(self.pending_turn_events)), daemon=True)
                self.recovery_thread.start()
            self.next_poll = self.monotonic() + 1

    def _titles_changed(self):
        with self.lock, self.store.connect() as db:
            if self.closed:
                return
            db.execute("BEGIN IMMEDIATE")
            self.publish(db)

    def publish(self, db, *, lifecycle_only=False) -> bool:
        self._persist_tracking(db)
        records = db.execute("SELECT s.* FROM omarchy_sessions s JOIN omarchy_processes p "
                             "ON p.session_id=s.id WHERE p.closed=0 ORDER BY s.id").fetchall()
        cutoff = time.time() - FINISHED_RETENTION
        child_pending = {row['id'] for row in db.execute('SELECT id,lifecycle FROM omarchy_claude')
                         if json.loads(row['lifecycle']).get('child_waits')}
        records = [row for row in records if row["state"] not in ("finished", "failed") or row["updated"] > cutoff
                   or row['id'] in child_pending or native_waiting(self.native_attention.get(row['id']), row['turn'])]
        now_monotonic = self.monotonic()
        self.titles.retain(row["id"] for row in records)
        sessions = []
        for row in records:
            question = self.pending_questions.get(row["id"])
            state = ("needs_input" if row["state"] not in ("finished", "failed", "idle")
                     and question and question[0] == row["turn"] and question[1] <= now_monotonic
                     else row["state"])
            session = {"id": row["id"], "provider": row["provider"], "state": state}
            if title := self.titles.name(row["id"]):
                session["name"] = title
            if row["provider"] == "claude":
                saved = db.execute("SELECT lifecycle FROM omarchy_claude WHERE id=?", (row["id"],)).fetchone()
                if saved:
                    current = ClaudeSession(**json.loads(saved[0]))
                    session["state"] = current.state(now_monotonic)
                    if current.remote_session_id:
                        session["remoteSessionID"] = current.remote_session_id
            native = self.native_attention.get(row["id"])
            if native_waiting(native, row['turn']):
                session['state'] = 'needs_input'
            elif native_empty(native, row['turn']) and row['state'] not in ('finished', 'failed', 'idle'):
                session['state'] = 'working'
            elif (native and not isinstance(native, PendingDecisions) and native[0] == row["turn"]
                  and row["state"] not in ("finished", "failed", "idle")):
                session["state"] = "needs_input" if native[1] else "working"
            sessions.append(session)
        # Needs-input takes precedence; active work wins over old completions.
        state = next((candidate for candidate in ("needs_input", "failed", "working", "finished")
                      if any(session["state"] == candidate for session in sessions)), "idle")
        activity_key = json.dumps([(row["id"], row["turn"], session["state"])
                                   for row, session in zip(records, sessions)])
        previous_key = db.execute("SELECT value FROM metadata WHERE key='activity_key'").fetchone()
        sessions_changed = previous_key is None or previous_key[0] != activity_key
        last = db.execute("SELECT * FROM events ORDER BY seq DESC LIMIT 1").fetchone()
        old = json.loads(last["payload"]) if last["payload"] else {}
        # A temporarily unavailable allowance file must not erase the last reading.
        current_allowances = (allowance_snapshots(self.state_dir / "agents/usage/codex.json", int(time.time()))
                              if "codex" in self.providers else [])
        allowances = (current_allowances or readings(old)) if "codex" in self.providers else []
        payload = {"sourceName": self.computer_name, "state": state, "sessions": sessions,
                   "configuredProviders": list(self.providers),
                   "allowance": selected_reading(allowances), "allowances": allowances}
        # Membership-only cleanup isn't a new alert. An aggregate state change
        # still needs a new event identity so an acknowledged watch state clears.
        activity_changed = sessions_changed and (not lifecycle_only or old.get("state") != state)
        if not sessions_changed and all(old.get(key) == value for key, value in payload.items()):
            return False
        now = time.time()
        kind = "activity" if activity_changed else "presentation"
        seq = db.execute("INSERT INTO events(at,state,label,kind) VALUES (?,?,?,?)",
                         (now, state, "Omarchy " + kind, kind)).lastrowid
        payload["eventID"] = str(seq) if activity_changed else old["eventID"]
        payload["changedAt"] = now if activity_changed else old["changedAt"]
        db.execute("UPDATE events SET payload=? WHERE seq=?", (json.dumps(payload, separators=(",", ":")), seq))
        db.execute("INSERT OR REPLACE INTO metadata VALUES ('activity_key',?)", (activity_key,))
        return True
