#!/usr/bin/env python3
"""Small, non-blocking Codex lifecycle adapter; no prompts or transcript content."""
import json
import os
from pathlib import Path
import socket
import sys
import unicodedata


EVENTS = {
    "SessionStart": "started", "UserPromptSubmit": "working",
    "PermissionRequest": "needs-input", "PostToolUse": "working",
    "Stop": "completed", "Interrupt": "interrupted", "SessionEnd": "ended",
}


def workspace_label(cwd):
    """Return a short project label without exporting a local filesystem path."""
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        return None
    path = Path(cwd)
    if path == Path.home():
        return None
    label = path.name
    for candidate in (path, *path.parents):
        if candidate == Path.home():
            break
        if (candidate / ".git").exists():
            label = candidate.name
            break
    if (not 1 <= len(label) <= 40 or "/" in label or "\\" in label
            or any(unicodedata.category(char).startswith("C") for char in label)):
        return None
    return label


def main():
    data = {}
    try:
        data = json.load(sys.stdin)
        event = EVENTS.get(data.get("hook_event_name"))
        session = data.get("session_id")
        turn = data.get("turn_id") or ""
        if event and isinstance(session, str):
            path = Path(os.environ.get("PACEMAN_HOOK_SOCKET", str(Path.home() / "Library/Application Support/Paceman/hook.sock")))
            message = {"command": "agent-event", "session": session, "turn": turn,
                       "event": event, "hook": data["hook_event_name"]}
            if label := workspace_label(data.get("cwd")):
                message["workspaceLabel"] = label
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(.15)
                connection.connect(str(path))
                connection.sendall(json.dumps(message, separators=(",", ":")).encode() + b"\n")
    except (OSError, ValueError, TypeError, KeyError):
        # Monitoring must never prevent an agent turn or approval from running.
        pass
    if data.get("hook_event_name") == "Stop":
        print('{"continue":true}')


if __name__ == "__main__":
    main()
