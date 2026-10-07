"""Shared Claude hook normalization and validation; conversation content is discarded."""
import hashlib
import os
import re

EVENTS = {
    "SessionStart": "started", "UserPromptSubmit": "working",
    "PreToolUse": "tool-started", "PermissionRequest": "needs-input",
    "PostToolUse": "tool-ended", "PostToolUseFailure": "tool-ended",
    "PostToolBatch": "batch-ended", "Elicitation": "needs-input",
    "ElicitationResult": "input-resolved", "Stop": "completed",
    "StopFailure": "failed", "SessionEnd": "ended",
}
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,160}\Z")
REMOTE_IDENTIFIER = re.compile(r"session_[A-Za-z0-9_-]{1,152}\Z")
QUESTIONS = {"AskUserQuestion", "ExitPlanMode"}


def message_for(data, workspace_label=None):
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
    # Local session IDs differ from the Remote Control ID exposed to hook subprocesses.
    remote_id = os.environ.get("CLAUDE_CODE_BRIDGE_SESSION_ID", "")
    message["remoteSessionID"] = remote_id if REMOTE_IDENTIFIER.fullmatch(remote_id) else None
    if workspace_label is not None and (label := workspace_label(data.get("cwd"))):
        message["workspaceLabel"] = label
    return message


def validate_message(command):
    hook, event, turn = (command.get(k) for k in ("hook", "event", "turn"))
    if (not isinstance(hook, str) or hook not in EVENTS
            or (not turn and hook not in ("SessionStart", "SessionEnd"))
            or (event != EVENTS[hook] and (hook, event) not in
                (("PreToolUse", "question-opened"), ("PostToolUseFailure", "interrupted")))):
        raise ValueError("Invalid Claude lifecycle")
    remote_id = command.get("remoteSessionID")
    if remote_id is not None and (not isinstance(remote_id, str) or not REMOTE_IDENTIFIER.fullmatch(remote_id)):
        raise ValueError("Invalid Claude remote session ID")
    for field in ("tool", "toolUse", "inputID"):
        value = command.get(field)
        if value is not None and (not isinstance(value, str) or not IDENTIFIER.fullmatch(value)):
            raise ValueError("Invalid Claude scope")
    if hook in ("PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure") and not command.get("tool"):
        raise ValueError("Missing tool scope")
    if hook in ("Elicitation", "ElicitationResult") and not command.get("inputID"):
        raise ValueError("Missing input scope")


CLAUDE_PURPOSES = (
    ('SessionStart', 'show a new or resumed Claude session as idle'),
    ('UserPromptSubmit', 'show work after a new prompt'),
    ('PreToolUse', 'observe work and questions or plan approval'),
    ('PermissionRequest', 'show approval pending after five seconds'),
    ('PostToolUse', 'clear attention after the corresponding tool returns'),
    ('PostToolUseFailure', 'clear tool attention; observe an interrupt when supplied'),
    ('PostToolBatch', 'clear attention when the tool batch returns'),
    ('Elicitation', 'show an MCP input request after five seconds'),
    ('ElicitationResult', 'clear the corresponding MCP input request'),
    ('Stop', 'show a finished main turn'),
    ('StopFailure', 'show a failed main turn'),
    ('SessionEnd', 'remove a closed session'),
)
