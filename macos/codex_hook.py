#!/usr/bin/env python3
"""Small, non-blocking Codex lifecycle adapter; no prompts or transcript content."""
import json
import os
from pathlib import Path
import socket
import sys
import time
import unicodedata


EVENTS = {
    "SessionStart": "started", "UserPromptSubmit": "working",
    "PermissionRequest": "needs-input", "PreToolUse": "needs-input",
    "PostToolUse": "working",
    "Stop": "completed", "Interrupt": "interrupted", "SessionEnd": "ended",
}
TERMINAL_HOOKS = {"Stop", "Interrupt", "SessionEnd"}
QUESTION_MATCHER = "^request_user_input(_async)?$"


def deliver(message, path, hook):
    """Require the source's receipt; briefly retry lifecycle-ending events."""
    deadline = time.monotonic() + (1.0 if hook in TERMINAL_HOOKS else 0.0)
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(.2 if hook in TERMINAL_HOOKS else .15)
                connection.connect(str(path))
                connection.sendall(json.dumps(message, separators=(",", ":")).encode() + b"\n")
                response = connection.makefile("rb").readline(256)
                if json.loads(response).get("ok") is True:
                    return
        except (OSError, ValueError, AttributeError):
            pass
        if time.monotonic() >= deadline:
            return
        time.sleep(min(.1, max(0, deadline - time.monotonic())))


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
        # A question is a tool call, not a permission request. The async call
        # returns before the answer, so its attention has a distinct lifecycle.
        if data.get("hook_event_name") == "PreToolUse":
            tool = data.get("tool_name")
            event = ("question-opened" if tool == "request_user_input_async"
                     else "needs-input" if tool == "request_user_input" else None)
        session = data.get("session_id")
        turn = data.get("turn_id") or ""
        if event and isinstance(session, str):
            path = Path(os.environ.get("PACEMAN_HOOK_SOCKET", str(Path.home() / "Library/Application Support/Paceman/hook.sock")))
            message = {"command": "agent-event", "session": session, "turn": turn,
                       "event": event, "hook": data["hook_event_name"]}
            if label := workspace_label(data.get("cwd")):
                message["workspaceLabel"] = label
            deliver(message, path, data["hook_event_name"])
    except (OSError, ValueError, TypeError, KeyError):
        # Monitoring must never prevent an agent turn or approval from running.
        pass
    if data.get("hook_event_name") == "Stop":
        print('{"continue":true}')


if __name__ == "__main__":
    main()
