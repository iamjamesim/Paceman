#!/usr/bin/env python3
"""Forward Claude lifecycle metadata; never affect agent permission decisions."""
import json
import os
from pathlib import Path
import socket
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from service.claude_hooks import message_for


def main():
    try:
        message = message_for(json.load(sys.stdin))
        if message:
            path = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "omarchy-watch.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(.2)
                client.connect(str(path))
                client.sendall((json.dumps(message) + "\n").encode())
                client.recv(4096)
    except (OSError, ValueError, TypeError, AttributeError):
        pass


if __name__ == "__main__":
    main()
