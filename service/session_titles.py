"""Read explicit provider titles; never use prompt or transcript previews."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import unicodedata
from uuid import UUID

from service.codex_limits import _response, _send, codex_binary

TITLE_REFRESH_INTERVAL = 30.0
CLAUDE_READ_BYTES = 65536
_TITLE_RECORD = re.compile(rb'^\s*\{\s*"type"\s*:\s*"(custom-title|ai-title)"')


def normalized_title(value):
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    value = "".join(char for char in value if not unicodedata.category(char).startswith("C"))
    return value[:80].strip() or None


def valid_session_id(value):
    try:
        return isinstance(value, str) and str(UUID(value)) == value.lower()
    except (ValueError, TypeError, AttributeError):
        return False


def read_codex_titles(sessions):
    valid = [session for session in dict.fromkeys(sessions) if valid_session_id(session)]
    binary = codex_binary()
    if not binary or not valid:
        return {}
    process = None
    titles = {}
    try:
        process = subprocess.Popen([binary, "app-server", "--stdio"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        deadline = time.monotonic() + 8
        _send(process, {"method": "initialize", "id": 1, "params": {
            "clientInfo": {"name": "paceman", "title": "Paceman", "version": "0.1.0"}}})
        if not _response(process, 1, deadline):
            return {}
        _send(process, {"method": "initialized", "params": {}})
        for request_id, session in enumerate(valid, 2):
            _send(process, {"method": "thread/read", "id": request_id,
                            "params": {"threadId": session, "includeTurns": False}})
            thread = _response(process, request_id, deadline).get("thread")
            if isinstance(thread, dict) and "name" in thread:
                # preview is prompt text, even when it looks like a title.
                titles[session] = normalized_title(thread["name"])
    except (OSError, ValueError, BrokenPipeError, OverflowError):
        pass
    finally:
        if process is not None:
            try:
                process.terminate()
                process.wait(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    process.kill()
                    process.wait(timeout=1)
                except OSError:
                    pass
            process.stdin.close()
            process.stdout.close()
    return titles


def read_claude_titles(sessions, *, projects=None):
    projects = projects or Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")) / "projects"
    titles = {}
    for session in dict.fromkeys(sessions):
        if not valid_session_id(session):
            continue
        try:
            paths = list(projects.glob(f"*/{session}.jsonl"))
            if not paths:
                continue
            path = max(paths, key=lambda path: path.stat().st_mtime_ns)
            with path.open("rb") as file:
                size = os.fstat(file.fileno()).st_size
                head = file.read(CLAUDE_READ_BYTES)
                offset = max(len(head), size - CLAUDE_READ_BYTES)
                file.seek(offset)
                tail = file.read(CLAUDE_READ_BYTES)
                if offset > len(head):
                    tail = tail.partition(b"\n")[2]  # Drop an incomplete first record.
        except OSError:
            continue
        values = {}
        for line in (head, tail):
            for record in line.splitlines():
                if not _TITLE_RECORD.match(record):
                    continue  # Do not parse messages, summaries or tool payloads.
                try:
                    row = json.loads(record)
                except (ValueError, UnicodeDecodeError):
                    continue
                field = "customTitle" if row.get("type") == "custom-title" else "aiTitle"
                if row.get("sessionId") not in (None, session):
                    continue
                if field in row:
                    values[field] = normalized_title(row[field])
        if values:
            titles[session] = values.get("customTitle") or values.get("aiTitle")
    return titles


def read_session_titles(refs):
    titles = {}
    for provider, reader in (("codex", read_codex_titles), ("claude", read_claude_titles)):
        rows = reader([session for kind, session in refs if kind == provider])
        titles.update({(provider, session): title for session, title in rows.items()})
    return titles


class SessionTitles:
    """Refresh local metadata off the hook path, scoped to live display rows."""
    def __init__(self, on_change, *, reader=read_session_titles, monotonic=time.monotonic):
        self.reader, self.on_change, self.monotonic = reader, on_change, monotonic
        self.lock = threading.RLock()
        self.refs, self.names = {}, {}
        self.next_refresh = 0.0
        self.thread = None
        self.closed = False

    def start(self):
        with self.lock:
            self.closed = False
            self.next_refresh = 0.0

    def track(self, key, provider, session):
        with self.lock:
            if self.closed:
                return
            ref = (provider, session)
            if self.refs.get(key, ())[:2] != ref:
                self.refs[key] = (*ref, object())
                self.names.pop(key, None)
                self.next_refresh = 0.0

    def retain(self, keys):
        with self.lock:
            for key in (self.refs.keys() | self.names.keys()) - set(keys):
                self.refs.pop(key, None)
                self.names.pop(key, None)

    def name(self, key):
        with self.lock:
            return self.names.get(key)

    def refresh(self):
        with self.lock:
            if (self.closed or not self.refs or self.monotonic() < self.next_refresh
                    or (self.thread is not None and self.thread.is_alive())):
                return
            self.next_refresh = self.monotonic() + TITLE_REFRESH_INTERVAL
            self.thread = threading.Thread(target=self._read, args=(dict(self.refs),), daemon=True)
            self.thread.start()

    def _read(self, tracked):
        try:
            titles = self.reader([ref[:2] for ref in tracked.values()])
        except Exception:
            return  # A title lookup failure never changes lifecycle or loses a saved title.
        changed = False
        with self.lock:
            if self.closed or not isinstance(titles, dict):
                return
            for key, ref in tracked.items():
                if self.refs.get(key) != ref or ref[:2] not in titles:
                    continue
                title = normalized_title(titles[ref[:2]])
                changed |= self.names.get(key) != title
                if title:
                    self.names[key] = title
                else:
                    self.names.pop(key, None)
        if changed:
            self.on_change()

    def close(self):
        with self.lock:
            self.closed = True
            self.refs.clear()
            self.names.clear()
