"""Private local status for the desktop panel; never exports client credentials."""
import json
import os
import socket
from pathlib import Path
import tempfile
import threading
import time


class DesktopStatus:
    def __init__(self, path: Path, store):
        self.path, self.store = path, store
        self.started = time.time()
        self.phone_seen = 0
        self.next_write = 0
        self.lock = threading.Lock()

    def phone_fetched(self):
        with self.lock:
            self.phone_seen = time.time()

    def publish(self, adapter=None, *, stopped=False, force=False):
        if not force and time.monotonic() < self.next_write:
            return
        snapshot = self.store.snapshot()
        session_counts = {state: sum(session["state"] == state for session in snapshot["sessions"])
                          for state in ("needs_input", "working", "finished", "idle")}
        with self.store.connect() as db:
            paired = db.execute("SELECT COUNT(*) FROM clients").fetchone()[0]
        with self.lock:
            phone_seen = self.phone_seen
        value = {
            "schema": 1, "running": not stopped, "updatedAt": time.time(),
            "startedAt": self.started, "mode": snapshot["mode"],
            "computerName": socket.gethostname(),
            "activity": snapshot["state"], "sessions": len(snapshot["sessions"]),
            "sessionCounts": session_counts,
            "sessionLiveness": snapshot.get("sessionLiveness"),
            "lastAgentEventAt": getattr(adapter, "last_event_at", 0),
            "pairedPhones": paired, "lastPhoneFetchAt": phone_seen,
        }
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor, temporary = tempfile.mkstemp(dir=self.path.parent, prefix=".status-")
        try:
            with os.fdopen(descriptor, "w") as output:
                json.dump(value, output, separators=(",", ":"))
            os.replace(temporary, self.path)
        finally:
            Path(temporary).unlink(missing_ok=True)
        self.next_write = time.monotonic() + 5
