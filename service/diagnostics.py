"""Bounded local delivery metadata. Never accepts request or response content."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time


def fingerprint(value):
    return hashlib.sha256(value.encode()).hexdigest()[:12]


class DeliveryDiagnostics:
    def __init__(self, path, maximum_bytes=1_000_000):
        self.path = Path(path)
        self.maximum_bytes = maximum_bytes

    def record(self, stage, **fields):
        enums = {
            "stage": {"http_received", "http_replied", "http_disconnected",
                      "hook_received", "hook_unsupported", "hook_failed", "hook_returned",
                      "request_published", "request_released", "request_rejected",
                      "response_submitted", "response_replayed", "native_requests_observed"},
            "operation": {"snapshot", "requests", "submit"},
            "provider": {"codex", "claude"}, "kind": {"approval", "question"},
            "action": {"answer", "choose", "allowOnce", "deny", "release"},
            "origin": {"phone", "watch"},
            "reason": {"deadline", "provider_disabled", "hook_disconnected", "access_changed", "shutdown",
                       "invalid_request", "unavailable", "busy"},
            "outcome": {"native", "responded"},
        }
        if stage not in enums["stage"]:
            return
        entry = {"at": time.time(), "stage": stage}
        for key, value in fields.items():
            if key in enums and isinstance(value, str) and value in enums[key]:
                entry[key] = value
            elif key in {"requestFingerprint", "sessionFingerprint"} and isinstance(value, str) and re.fullmatch(r"[0-9a-f]{12}", value):
                entry[key] = value
            elif key == "traceID" and isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F-]{36}", value):
                entry[key] = value
            elif key in {"durationMs", "httpStatus", "pendingCount", "errorNumber", "humanCount",
                         "internalCount", "unknownCount", "invalidCount"} and type(value) is int and 0 <= value < 2**32:
                entry[key] = value
        # Hooks and the source can write concurrently. Diagnostics never wait
        # on another writer and never change a request's outcome on failure.
        fd = None
        try:
            fd = os.open(self.path, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                return
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            data = (json.dumps(entry, separators=(",", ":")) + "\n").encode()
            if os.fstat(fd).st_size + len(data) > self.maximum_bytes:
                os.ftruncate(fd, 0)
            os.write(fd, data)
        except OSError:
            pass
        finally:
            if fd is not None:
                os.close(fd)
