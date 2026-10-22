#!/usr/bin/env python3
"""Small, non-blocking Codex lifecycle adapter; no prompts or transcript content."""
import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import time
import uuid


EVENTS = {
    "SessionStart": "started", "UserPromptSubmit": "working",
    "PermissionRequest": "needs-input", "PreToolUse": "needs-input",
    "PostToolUse": "working",
    "Stop": "completed", "Interrupt": "interrupted", "SessionEnd": "ended",
}
QUESTION_MATCHER = "^request_user_input(_async)?$"

# Direct hook scripts run with an isolated interpreter.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from service.hook_delivery import deliver as _deliver, workspace_label, TERMINAL_HOOKS


def deliver(message, path, hook):
    return _deliver(message, path, hook, clock=time)


def attention_key(data):
    """Match documented tool input without exporting it to the source.

    PermissionRequest has no documented tool_use_id. Count each invocation and
    correlate completions by tool/input scope, never by unrelated tool activity.
    """
    tool, arguments = data.get("tool_name"), data.get("tool_input")
    if not isinstance(tool, str) or arguments is None:
        return None
    if tool in ("Bash", "PowerShell", "apply_patch") and isinstance(arguments, dict):
        # Description is an approval reason for these canonical built-ins only.
        arguments = {k: v for k, v in arguments.items() if k != "description"}
    encoded = json.dumps([tool, data.get("cwd"), arguments], sort_keys=True,
                         separators=(",", ":"), allow_nan=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def main():
    data = {}
    try:
        data = json.load(sys.stdin)
        event = EVENTS.get(data.get("hook_event_name"))
        # A question is a tool call, not a permission request. The async call
        # returns before the answer, so its attention has a distinct lifecycle.
        if data.get("hook_event_name") == "PreToolUse":
            tool = data.get("tool_name")
            event = "question-opened" if tool in ("request_user_input", "request_user_input_async") else None
        if data.get("hook_event_name") == "PostToolUse" and data.get("tool_name") == "request_user_input":
            event = "question-answered"
        session = data.get("session_id")
        turn = data.get("turn_id") or ""
        if event and isinstance(session, str):
            path = Path(os.environ.get("PACEMAN_HOOK_SOCKET", str(Path.home() / "Library/Application Support/Paceman/hook.sock")))
            message = {"command": "agent-event", "session": session, "turn": turn,
                       "event": event, "hook": data["hook_event_name"]}
            if data.get("hook_event_name") in ("PermissionRequest", "PostToolUse"):
                if scope := attention_key(data):
                    message["attentionKey"] = scope
                if data.get("hook_event_name") == "PermissionRequest":
                    message["approvalToken"] = str(uuid.uuid4())
            tool_id = data.get("tool_use_id")
            if isinstance(tool_id, str) and 0 < len(tool_id) <= 160:
                message["toolID"] = tool_id
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
