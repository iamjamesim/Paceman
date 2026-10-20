#!/usr/bin/env python3
"""Observe local Claude Code hooks without changing permission or stop decisions."""
import json
import os
from pathlib import Path
import sys
import socket

if __package__:
    from .codex_hook import deliver, workspace_label
else:
    from codex_hook import deliver, workspace_label

# Direct scripts run with an isolated interpreter; import only the installed package.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from service.claude_hooks import EVENTS, message_for as normalize_message
from service.claude_request_scope import binding


def withdraw_completed(data):
    hook = data.get("hook_event_name")
    if hook == "PostToolBatch":
        for tool in data.get("tool_calls", []):
            if isinstance(tool, dict):
                withdraw_completed({**data, **tool, "hook_event_name": "PostToolUse"})
        return
    field = ("scope" if hook in ("PostToolUse", "PostToolUseFailure", "PermissionDenied") else
             "turn" if hook in ("Stop", "StopFailure") else "session" if hook == "SessionEnd" else None)
    if field is None or data.get("agent_id"):
        return
    scope = binding(data)
    if not scope or field not in scope:
        return
    path = os.environ.get("PACEMAN_INTERACTION_SOCKET") or str(Path.home() / "Library/Application Support/Paceman/interaction.sock")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(.15)
            connection.connect(path)
            connection.sendall(json.dumps({"nativeResolved": {"field": field, "value": scope[field]}}).encode() + b"\n")
    except OSError:
        pass


def message_for(data):
    return normalize_message(data, workspace_label)


def main():
    try:
        data = json.load(sys.stdin)
        withdraw_completed(data)
        message = message_for(data)
        if message:
            path = Path(os.environ.get("PACEMAN_HOOK_SOCKET", str(
                Path.home() / "Library/Application Support/Paceman/hook.sock")))
            terminal = message["event"] in ("completed", "failed", "ended", "interrupted")
            deliver(message, path, "Stop" if terminal else message["hook"])
    except (OSError, ValueError, TypeError, AttributeError):
        pass  # Monitoring must never block an agent or print conversation context.


if __name__ == "__main__":
    main()
