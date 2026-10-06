"""Omarchy event receiver without Bluetooth ownership.

Accepts Paceman's Codex and Claude hooks and the older omarchy-watch-codex protocol. Only
opaque IDs and lifecycle states are retained; hook arguments and conversation
content are ignored.
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

from service.allowance import allowance_snapshot
from service.claude import ClaudeSession
from service.claude_hooks import validate_message
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
                 processes=None, computer_name: str | None = None, monotonic=time.monotonic, providers=("codex",), settings_reader=None):
        self.providers = tuple(providers)
        self.settings_reader = settings_reader
        self.last_event_by_provider = {}
        self.store = store
        self.socket_path = socket_path or default_socket()
        self.state_dir = state_dir or Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy"
        self.lock = threading.RLock()
        self.next_poll = 0.0
        self.server = None
        self.thread = None
        self.socket_inode = None
        self.last_event_at = 0
        self.pending_questions = {}
        self.native_turns = {}
        self.monotonic = monotonic
        self.processes = processes if processes is not None else AgentProcesses()
        self.computer_name = (computer_name or socket.gethostname()).split(".")[0][:80] or "Computer"

    def __enter__(self):
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
                for row in db.execute("SELECT key,value FROM metadata WHERE key LIKE 'omarchy_last_event_%'"):
                    self.last_event_by_provider[row["key"].removeprefix("omarchy_last_event_")] = float(row["value"])
                self.last_event_at = max(self.last_event_by_provider.values(), default=0)
                db.execute("INSERT OR REPLACE INTO metadata VALUES ('mode','omarchy')")
                db.execute("DELETE FROM schedule WHERE fired=0")
                # Legacy records cannot establish ownership. A new hook registers
                # them; don't carry old anonymous completions into the live list.
                db.execute("UPDATE omarchy_sessions SET state='idle' WHERE id NOT IN "
                           "(SELECT session_id FROM omarchy_processes)")
            self.tick(force=True)
            self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=.05), daemon=True)
            self.thread.start()
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *_):
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
                if same_owner and previous["turn"] != turn and event != "working":
                    return self.publish(db, lifecycle_only=True)
                if previous["turn"] == turn:
                    if same_owner and (binding["closed"] or (previous["state"] == "idle" and event != "ended")):
                        return self.publish(db, lifecycle_only=True)
                    if (same_owner and previous["state"] == EVENTS[event]
                            and event != "ended" and not async_question
                            and command.get("hook") != "UserPromptSubmit"):
                        if native:
                            self.native_turns[key] = turn
                        return self.publish(db, lifecycle_only=True)
                    if same_owner and previous["state"] in ("idle", "finished") and event in ("working", "needs-input"):
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
            if native:
                self.native_turns[key] = turn
            if async_question:
                self.pending_questions[key] = (turn, self.monotonic() + ATTENTION_DELAY)
            elif event in ("completed", "interrupted", "ended") or command.get("hook") == "UserPromptSubmit":
                self.pending_questions.pop(key, None)
            state = (previous["state"] if async_question and previous and previous["turn"] == turn
                     else "working" if async_question else EVENTS[event])
            db.execute("INSERT OR REPLACE INTO omarchy_processes VALUES (?,?,?,?,0)",
                       (key, owner.pid, owner.start_ticks, owner.boot_id))
            db.execute("INSERT OR REPLACE INTO omarchy_sessions VALUES (?,?,?,?,?)",
                       (key, source, turn, state, time.time()))
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
            if event == "started":
                if binding is not None:
                    self.record_event(db, "claude")
                    return self.publish(db, lifecycle_only=True)
            elif event == "ended":
                if binding is None:
                    return self.publish(db, lifecycle_only=True)
                if turn and current.turn and turn != current.turn:
                    return self.publish(db, lifecycle_only=True)
                current.base_state = "idle"
                current.waits.clear()
                current.tools.clear()
            elif not current.receive({**command, "workspaceLabel": None}, self.monotonic(), ATTENTION_DELAY):
                return self.publish(db, lifecycle_only=True)
            # Linux monotonic time is shared across processes within a boot.
            # Ownership reconciliation rejects records from earlier boots.
            if len(current.waits) > 128 or len(current.tools) > 128:
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
            self.record_event(db, "claude")
            return self.publish(db, lifecycle_only=event in ("started", "ended"))

    @staticmethod
    def identity(row):
        return ProcessIdentity(row["pid"], row["start_ticks"], row["boot_id"])

    def prune_processes(self, db):
        for row in db.execute("SELECT * FROM omarchy_processes").fetchall():
            if not self.processes.is_alive(self.identity(row)):
                db.execute("UPDATE omarchy_sessions SET state='idle' WHERE id=?", (row["session_id"],))
                db.execute("DELETE FROM omarchy_processes WHERE session_id=?", (row["session_id"],))
                db.execute("DELETE FROM omarchy_claude WHERE id=?", (row["session_id"],))
                self.pending_questions.pop(row["session_id"], None)
                self.native_turns.pop(row["session_id"], None)

    def tick(self, *, force=False):
        with self.lock:
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
            self.next_poll = self.monotonic() + 1

    def publish(self, db, *, lifecycle_only=False) -> bool:
        records = db.execute("SELECT s.* FROM omarchy_sessions s JOIN omarchy_processes p "
                             "ON p.session_id=s.id WHERE p.closed=0 ORDER BY s.id").fetchall()
        cutoff = time.time() - FINISHED_RETENTION
        records = [row for row in records if row["state"] not in ("finished", "failed") or row["updated"] > cutoff]
        now_monotonic = self.monotonic()
        sessions = []
        for row in records:
            question = self.pending_questions.get(row["id"])
            state = ("needs_input" if row["state"] not in ("finished", "idle")
                     and question and question[0] == row["turn"] and question[1] <= now_monotonic
                     else row["state"])
            if row["provider"] == "claude":
                saved = db.execute("SELECT lifecycle FROM omarchy_claude WHERE id=?", (row["id"],)).fetchone()
                if saved:
                    state = ClaudeSession(**json.loads(saved[0])).state(now_monotonic)
            sessions.append({"id": row["id"], "provider": row["provider"], "state": state})
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
        current_allowance = (allowance_snapshot(self.state_dir / "agents/usage/codex.json", int(time.time()))
                             if "codex" in self.providers else None)
        payload = {"sourceName": self.computer_name, "state": state, "sessions": sessions,
                   "configuredProviders": list(self.providers),
                   "allowance": (current_allowance if current_allowance is not None else old.get("allowance"))
                   if "codex" in self.providers else None}
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
