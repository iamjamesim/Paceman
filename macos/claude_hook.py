#!/usr/bin/env python3
"""Observe local Claude Code hooks without changing permission or stop decisions."""
import json
import os
from pathlib import Path
import sys

if __package__:
    from .codex_hook import deliver, workspace_label
else:
    from codex_hook import deliver, workspace_label

# Direct scripts run with an isolated interpreter; import only the installed package.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from service.claude_hooks import EVENTS, REMOTE_IDENTIFIER, message_for as normalize_message


def message_for(data):
    message = normalize_message(data, workspace_label)
    if message is not None:
        # The local hook session ID is not the Remote Control session ID.
        remote_id = os.environ.get("CLAUDE_CODE_BRIDGE_SESSION_ID", "")
        message["remoteSessionID"] = remote_id if REMOTE_IDENTIFIER.fullmatch(remote_id) else None
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
