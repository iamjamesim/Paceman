#!/usr/bin/env python3
"""Observe local Claude Code hooks without changing permission or stop decisions."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys

if __package__:
    from .codex_hook import deliver, workspace_label
else:
    from codex_hook import deliver, workspace_label

EVENTS = {
    "SessionStart": "started", "UserPromptSubmit": "working",
    "PreToolUse": "tool-started", "PermissionRequest": "needs-input",
    "PostToolUse": "tool-ended", "PostToolUseFailure": "tool-ended",
    "PostToolBatch": "batch-ended", "Elicitation": "needs-input",
    "ElicitationResult": "input-resolved", "Stop": "completed",
    "StopFailure": "failed", "SessionEnd": "ended",
}
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,160}\Z")
QUESTIONS = {"AskUserQuestion", "ExitPlanMode"}


def message_for(data):
    if not isinstance(data, dict) or data.get("agent_id"):
        return None  # Subagent completion must never finish its parent session.
    hook = data.get("hook_event_name")
    event = EVENTS.get(hook) if isinstance(hook, str) else None
    session, turn = data.get("session_id"), data.get("prompt_id", "")
    if (not event or not isinstance(session, str) or not IDENTIFIER.fullmatch(session)
            or not isinstance(turn, str) or (turn and not IDENTIFIER.fullmatch(turn))):
        return None
    # prompt_id is documented from Claude Code 2.1.196. Without it, a delayed
    # callback could finish a newer prompt. Do not guess at turn boundaries.
    if not turn and hook not in ("SessionStart", "SessionEnd"):
        return None
    message = {"command": "agent-event", "provider": "claude", "session": session,
               "turn": turn, "hook": hook, "event": event}
    if hook in ("PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure"):
        tool = data.get("tool_name")
        if not isinstance(tool, str) or not 1 <= len(tool) <= 256:
            return None
        message["tool"] = hashlib.sha256(tool.encode()).hexdigest()
        tool_id = data.get("tool_use_id")
        if isinstance(tool_id, str) and IDENTIFIER.fullmatch(tool_id):
            message["toolUse"] = tool_id
        if hook == "PreToolUse" and tool in QUESTIONS:
            message["event"] = "question-opened"
        if hook == "PostToolUseFailure" and data.get("is_interrupt") is True:
            message["event"] = "interrupted"
    if hook in ("Elicitation", "ElicitationResult"):
        # A hash scopes concurrent MCP forms without exporting server names/URLs.
        scope = data.get("elicitation_id") or data.get("mcp_server_name")
        if not isinstance(scope, str) or not 1 <= len(scope) <= 256:
            return None
        message["inputID"] = hashlib.sha256(scope.encode()).hexdigest()
    if label := workspace_label(data.get("cwd")):
        message["workspaceLabel"] = label
    return message


def main():
    try:
        data = json.load(sys.stdin)
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
