"""Read the local Codex account's limits through the public App Server API.

This is an optional, read-only source for the existing watch allowance field.
No account credentials or account identifiers leave the Mac.
"""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import plistlib
import select
import shutil
import subprocess
import time


TIMEOUT_SECONDS = 8
MAX_RESPONSE_BYTES = 1_048_576


def codex_binary(*, application_dirs: tuple[Path, ...] | None = None) -> str | None:
    if application_dirs is None:
        application_dirs = (Path("/Applications"), Path.home() / "Applications")
    # Prefer the runtime owned by the desktop client. A separately installed CLI
    # may be signed in to another account. This is an optional bundle detail,
    # verified by bundle ID and executable presence rather than assumed.
    candidates = [os.environ.get("PACEMAN_CODEX_BIN")]
    for directory in application_dirs:
        for name in ("Codex.app", "ChatGPT.app"):
            bundle = directory / name
            try:
                info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            except (OSError, ValueError, TypeError):
                continue
            if isinstance(info, dict) and info.get("CFBundleIdentifier") == "com.openai.codex":
                candidates.append(str(bundle / "Contents/Resources/codex"))
    candidates.extend((shutil.which("codex"), "/opt/homebrew/bin/codex", "/usr/local/bin/codex"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
    return None


def _response(process: subprocess.Popen, request_id: int, deadline: float) -> dict:
    pending = bytearray()
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            break
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            break
        pending.extend(chunk)
        if len(pending) > MAX_RESPONSE_BYTES:
            break
        while b"\n" in pending:
            line, _, rest = pending.partition(b"\n")
            pending = bytearray(rest)
            try:
                message = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                continue
            if isinstance(message, dict) and message.get("id") == request_id:
                result = message.get("result")
                return result if isinstance(result, dict) else {}
    return {}


def _send(process: subprocess.Popen, message: dict):
    process.stdin.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
    process.stdin.flush()


def parse_codex_allowance(result: dict, observed_at: int) -> dict | None:
    """Map the most depleted recognized Codex window to watch profile v5."""
    if not isinstance(result, dict):
        return None
    buckets = result.get("rateLimitsByLimitId")
    bucket = buckets.get("codex") if isinstance(buckets, dict) else None
    if bucket is None:
        bucket = result.get("rateLimits")
    if not isinstance(bucket, dict) or bucket.get("limitId") != "codex":
        return None
    windows = []
    for key in ("primary", "secondary"):
        item = bucket.get(key)
        if item is None:
            continue
        if not isinstance(item, dict):
            return None
        used, minutes, reset = (item.get(k) for k in ("usedPercent", "windowDurationMins", "resetsAt"))
        if (type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 100
                or type(minutes) is not int or not 0 < minutes <= 10080
                or type(reset) is not int or not observed_at < reset <= 3155759999):
            return None
        windows.append((used, 1 if minutes == 10080 else 2, reset, minutes))
    if not windows:
        return None
    # A tie does not make the shorter window more useful to show.
    used, window, reset, minutes = max(windows, key=lambda item: (item[0], item[1] == 1))
    return {"provider": "codex", "remaining": int(math.floor(100 - used + 0.5)),
            "window": window, "windowDurationMins": minutes,
            "updatedAt": observed_at, "resetsAt": reset}


def read_codex_allowance() -> dict | None:
    binary = codex_binary()
    if binary is None:
        return None
    process = None
    try:
        process = subprocess.Popen([binary, "app-server", "--stdio"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        deadline = time.monotonic() + TIMEOUT_SECONDS
        _send(process, {"method": "initialize", "id": 1, "params": {
            "clientInfo": {"name": "paceman", "title": "Paceman", "version": "0.1.0"}}})
        if not _response(process, 1, deadline):
            return None
        _send(process, {"method": "initialized", "params": {}})
        _send(process, {"method": "account/read", "id": 2, "params": {"refreshToken": False}})
        account = _response(process, 2, deadline).get("account")
        if not isinstance(account, dict) or account.get("type") != "chatgpt":
            return None
        _send(process, {"method": "account/rateLimits/read", "id": 3, "params": {}})
        return parse_codex_allowance(_response(process, 3, deadline), int(time.time()))
    except (OSError, ValueError, BrokenPipeError, OverflowError):
        return None
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
