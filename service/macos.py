"""Local Codex hook receiver for the macOS Paceman source.

The private Unix socket is reachable only through a user-owned directory. Hook
payloads are reduced to session/turn IDs and lifecycle states before storage.
"""
from __future__ import annotations

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

from service.codex_limits import read_codex_allowance


EVENT_STATES = {
    "started": "idle", "working": "working", "needs-input": "needs_input",
    "completed": "finished", "interrupted": "idle", "ended": "idle",
}
ATTENTION_DELAY = 5.0
FINISHED_RETENTION = 10 * 60
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
                 allowance_reader=read_codex_allowance, monotonic=time.monotonic):
        self.store = store
        self.socket_path = socket_path
        self.computer_name = (computer_name or socket.gethostname()).split(".")[0][:80]
        self.lock = threading.RLock()
        self.server = None
        self.thread = None
        self.socket_inode = None
        self.last_event_at = 0
        self.allowance_reader = allowance_reader
        self.allowance = None
        self.allowance_thread = None
        self.next_allowance_at = 0.0
        self.closed = False
        self.monotonic = monotonic
        self.pending_attention = {}

    def __enter__(self):
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
        if self.thread is not None:
            self.server.shutdown()
            self.thread.join(timeout=2)
        if self.allowance_thread is not None:
            self.allowance_thread.join(timeout=2)
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
        session, turn, event = (command.get(key) for key in ("session", "turn", "event"))
        if (not isinstance(session, str) or not IDENTIFIER.fullmatch(session)
                or not isinstance(turn, str) or (turn and not IDENTIFIER.fullmatch(turn))
                or event not in EVENT_STATES):
            raise ValueError("Invalid event")
        workspace_label = command.get("workspaceLabel")
        if workspace_label is not None:
            if (not isinstance(workspace_label, str) or not 1 <= len(workspace_label) <= 40
                    or workspace_label != workspace_label.strip()
                    or "/" in workspace_label or "\\" in workspace_label
                    or any(unicodedata.category(char).startswith("C") for char in workspace_label)):
                workspace_label = None
        key = hashlib.sha256(("codex:" + session).encode()).hexdigest()
        with self.lock, self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT * FROM mac_sessions WHERE id=?", (key,)).fetchone()
            if event == "ended":
                pending = self.pending_attention.pop(key, None)
                if previous is None and pending is None:
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
                    return False
                if (previous and previous["turn"] == turn and previous["state"] == "finished"
                        and event == "working" and command.get("hook") == "PostToolUse"):
                    return False
                if event == "needs-input":
                    pending = self.pending_attention.get(key)
                    if (pending and pending[0] == turn) or (previous and previous["turn"] == turn
                            and previous["state"] == "needs_input"):
                        return False
                    self.pending_attention[key] = (turn, self.monotonic() + ATTENTION_DELAY,
                                                   workspace_label)
                    self.last_event_at = time.time()
                    db.execute("INSERT OR REPLACE INTO metadata VALUES ('mac_last_agent_event_at',?)",
                               (str(self.last_event_at),))
                    return False
                self.pending_attention.pop(key, None)
                if (previous and previous["turn"] == turn and previous["state"] == EVENT_STATES[event]
                        and previous["workspace_label"] == workspace_label):
                    return False
                db.execute("INSERT OR REPLACE INTO mac_sessions VALUES (?,?,?,?,?)",
                           (key, turn, EVENT_STATES[event], time.time(), workspace_label))
            self.last_event_at = time.time()
            db.execute("INSERT OR REPLACE INTO metadata VALUES ('mac_last_agent_event_at',?)",
                       (str(self.last_event_at),))
            return self._publish(db)

    def tick(self):
        # Hook lifecycle events own session state. Elapsed time alone is not
        # evidence that a working or waiting Codex conversation has ended.
        with self.lock:
            if self.closed:
                return
            now = self.monotonic()
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
                        if previous and previous["state"] in ("needs_input", "finished"):
                            continue
                        db.execute("INSERT OR REPLACE INTO mac_sessions VALUES (?,?,?,?,?)",
                                   (key, turn, "needs_input", time.time(), workspace_label))
                        changed = True
                    if changed:
                        self._publish(db)
            # Stop completes a turn, but some clients do not deliver SessionEnd.
            # Keep its result long enough to notice, then retire only that
            # finished display row. A later prompt creates it again.
            with self.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                retired = db.execute("DELETE FROM mac_sessions WHERE state='finished' AND updated<=?",
                                     (time.time() - FINISHED_RETENTION,)).rowcount
                if retired:
                    self._publish(db, lifecycle_only=True)
            if now < self.next_allowance_at:
                return
            self.next_allowance_at = now + 300
            self.allowance_thread = threading.Thread(target=self._refresh_allowance, daemon=True)
            self.allowance_thread.start()

    def _refresh_allowance(self):
        try:
            allowance = self.allowance_reader()
        except Exception:
            allowance = None
        with self.lock:
            if self.closed:
                return
            self.allowance = allowance
            self.publish_current()

    def publish_current(self):
        with self.lock, self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._publish(db)

    def _publish(self, db, *, lifecycle_only=False) -> bool:
        records = db.execute("SELECT * FROM mac_sessions ORDER BY id").fetchall()
        sessions = []
        for row in records:
            session = {"id": row["id"], "provider": "codex", "state": row["state"]}
            if row["workspace_label"]:
                session["workspaceLabel"] = row["workspace_label"]
            sessions.append(session)
        state = next((candidate for candidate in ("needs_input", "working", "finished")
                      if any(row["state"] == candidate for row in records)), "idle")
        activity_key = json.dumps([(row["id"], row["turn"], row["state"]) for row in records])
        old_key = db.execute("SELECT value FROM metadata WHERE key='activity_key'").fetchone()
        last = db.execute("SELECT * FROM events ORDER BY seq DESC LIMIT 1").fetchone()
        old = json.loads(last["payload"]) if last["payload"] else {}
        payload = {"sourceName": self.computer_name, "mode": "macos", "state": state,
                   "sessions": sessions, "sessionLiveness": "hook", "allowance": self.allowance}
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
