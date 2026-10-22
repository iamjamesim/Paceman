#!/usr/bin/env python3
"""Forward Claude lifecycle metadata; never affect agent permission decisions."""
import json
import os
from pathlib import Path
import socket
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from service.claude_hooks import message_for as normalize_message
from service.hook_delivery import deliver, workspace_label


def message_for(data):
    return normalize_message(data, workspace_label)


def main():
    try:
        message = message_for(json.load(sys.stdin))
        if message:
            path = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "omarchy-watch.sock"
            terminal = message['event'] in ('completed', 'failed', 'ended', 'interrupted')
            deliver(message, path, 'Stop' if terminal else message['hook'])
    except (OSError, ValueError, TypeError, AttributeError):
        pass


if __name__ == "__main__":
    main()
