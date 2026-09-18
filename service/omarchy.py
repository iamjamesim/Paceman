"""Omarchy event receiver and resolved theme collector, without Bluetooth ownership.

Accepts the existing omarchy-watch-codex agent-event protocol. Only opaque IDs and
lifecycle states are retained; hook arguments and conversation content are ignored.
Palette resolution is adapted from Omarchy Watch v0.6.1 (MIT; see notices).
"""
from __future__ import annotations

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
import tomllib

MAX_AGE = 24 * 60 * 60
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,160}\Z")
EVENTS = {"working": "working", "needs-input": "needs_input", "completed": "finished",
          "interrupted": "idle", "ended": "idle"}


def default_socket() -> Path:
    return Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "omarchy-watch.sock"


def appearance(state_dir: Path) -> dict | None:
    """Use the same bar overrides and accent contrast threshold as the desktop."""
    current = state_dir / "current"
    try:
        colors = tomllib.loads((current / "theme/colors.toml").read_text())
        palette = {key: colors.get(key) for key in ("background", "foreground", "accent")}
        try:
            bar = tomllib.loads((current / "theme/shell.toml").read_text()).get("bar", {})
            for key, role in (("background", "background"), ("foreground", "text")):
                if isinstance(bar, dict) and re.fullmatch(r"#[0-9a-fA-F]{6}", str(bar.get(role, ""))):
                    palette[key] = bar[role]
        except (OSError, ValueError):
            pass
        if not all(isinstance(color, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", color)
                   for color in palette.values()):
            return None
        def luminance(color):
            channels = [channel / 255 for channel in bytes.fromhex(color[1:])]
            linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in channels]
            return sum(v * weight for v, weight in zip(linear, (.2126, .7152, .0722)))
        low, high = sorted(luminance(palette[key]) for key in ("background", "accent"))
        if (high + .05) / (low + .05) < 3:
            palette["accent"] = palette["foreground"]
        try:
            name = (current / "theme.name").read_text().strip()[:80]
        except OSError:
            name = "Omarchy"
        return {"id": "omarchy-current", "name": name or "Omarchy", "monospaced": True,
                **{key: value[1:].upper() for key, value in palette.items()}}
    except (OSError, ValueError):
        return None


class EventHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(.25)
        try:
            if hasattr(socket, "SO_PEERCRED"):
                _, uid, _ = struct.unpack("3i", self.connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if uid != os.getuid():
                    return
            raw = self.rfile.readline(4097)
            if len(raw) > 4096 or not raw.endswith(b"\n"):
                raise ValueError("Invalid event")
            changed = self.server.source.receive(json.loads(raw))
            response = {"ok": True, "changed": changed}
        except (ValueError, TypeError, TimeoutError):
            response = {"ok": False, "error": "invalid_event"}
        try:
            self.wfile.write(json.dumps(response).encode() + b"\n")
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass


class OmarchySource:
    def __init__(self, store, *, socket_path: Path | None = None, state_dir: Path | None = None):
        self.store = store
        self.socket_path = socket_path or default_socket()
        self.state_dir = state_dir or Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy"
        self.lock = threading.RLock()
        self.next_poll = 0.0
        self.server = None
        self.thread = None
        self.socket_inode = None
        self.last_event_at = 0

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
                db.execute("INSERT OR REPLACE INTO metadata VALUES ('mode','omarchy')")
                db.execute("DELETE FROM schedule WHERE fired=0")
                # Hooks have no heartbeat/replay. Don't claim interrupted activity survived a restart.
                db.execute("DELETE FROM omarchy_sessions WHERE state IN ('working','needs_input')")
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

    def receive(self, command: dict) -> bool:
        if not isinstance(command, dict) or command.get("command") != "agent-event":
            raise ValueError("Unsupported command")
        source, session, turn = (command.get(key) for key in ("source", "session", "turn"))
        event = command.get("event")
        if (not all(isinstance(value, str) and IDENTIFIER.fullmatch(value) for value in (source, session))
                or not isinstance(event, str) or event not in EVENTS
                or not isinstance(turn, str)
                or not (IDENTIFIER.fullmatch(turn) or (turn == "" and event in ("ended", "interrupted")))):
            raise ValueError("Invalid event")
        # Namespaced opaque keys keep session IDs out of the phone's presentation.
        key = hashlib.sha256(f"{source}:{session}".encode()).hexdigest()
        with self.lock, self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT * FROM omarchy_sessions WHERE id=?", (key,)).fetchone()
            if not turn:
                if previous is None:
                    return False
                turn = previous["turn"]
            if ((previous is None or previous["state"] == "idle") and EVENTS[event] != "idle"
                    and db.execute("SELECT COUNT(*) FROM omarchy_sessions WHERE state!='idle'").fetchone()[0] >= 100):
                raise ValueError("Too many active sessions")
            if previous:
                if previous["turn"] != turn and event != "working":
                    return False  # A delayed stop/input/cleanup cannot replace a newer turn.
                if previous["turn"] == turn:
                    if previous["state"] == EVENTS[event]:
                        return False
                    if previous["state"] in ("idle", "finished") and event in ("working", "needs-input"):
                        return False  # Do not resurrect a closed turn from delayed tool hooks.
            db.execute("INSERT OR REPLACE INTO omarchy_sessions VALUES (?,?,?,?,?)",
                       (key, source, turn, EVENTS[event], time.time()))
            self.last_event_at = time.time()
            return self.publish(db)

    def tick(self, *, force=False):
        with self.lock:
            if not force and time.monotonic() < self.next_poll:
                return
            with self.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                db.execute("DELETE FROM omarchy_sessions WHERE updated<?", (time.time() - MAX_AGE,))
                self.publish(db)
            self.next_poll = time.monotonic() + 1

    def publish(self, db) -> bool:
        records = db.execute("SELECT * FROM omarchy_sessions WHERE state!='idle' ORDER BY id").fetchall()
        sessions = [{"id": row["id"], "provider": row["provider"], "state": row["state"]} for row in records]
        # Needs-input takes precedence; active work wins over old completions.
        state = next((state for state in ("needs_input", "working", "finished")
                      if any(row["state"] == state for row in records)), "idle")
        activity_key = json.dumps([(row["id"], row["turn"], row["state"]) for row in records])
        previous_key = db.execute("SELECT value FROM metadata WHERE key='activity_key'").fetchone()
        activity_changed = previous_key is None or previous_key[0] != activity_key
        payload = {"sourceName": "Omarchy", "mode": "omarchy", "state": state, "sessions": sessions,
                   "appearance": appearance(self.state_dir)}
        last = db.execute("SELECT * FROM events ORDER BY seq DESC LIMIT 1").fetchone()
        old = json.loads(last["payload"]) if last["payload"] else {}
        if not activity_changed and all(old.get(key) == value for key, value in payload.items()):
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
