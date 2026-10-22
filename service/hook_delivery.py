"""Bounded hook delivery and safe project metadata shared by desktop clients."""
import json
import os
from pathlib import Path
import socket
import time
import unicodedata

TERMINAL_HOOKS = {'Stop', 'StopFailure', 'Interrupt', 'SessionEnd'}


def deliver(message, path, hook, *, clock=None):
    """Require a receipt; briefly retry ending events without a durable queue."""
    clock = clock or time
    deadline = clock.monotonic() + (1.0 if hook in TERMINAL_HOOKS else 0.0)
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(.2 if hook in TERMINAL_HOOKS else .15)
                connection.connect(str(path))
                connection.sendall(json.dumps(message, separators=(',', ':')).encode() + b'\n')
                with connection.makefile('rb') as response:
                    if json.loads(response.readline(256)).get('ok') is True:
                        return True
        except (OSError, ValueError, AttributeError):
            pass
        if clock.monotonic() >= deadline:
            return False
        clock.sleep(min(.1, max(0, deadline - clock.monotonic())))


def validated_label(label):
    if (not isinstance(label, str) or not 1 <= len(label) <= 40 or label != label.strip()
            or '/' in label or '\\' in label
            or any(unicodedata.category(char).startswith('C') for char in label)):
        return None
    return label


def workspace_label(cwd):
    """Export a bounded project label, never a local path."""
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        return None
    path = Path(cwd)
    if path == Path.home():
        return None
    label = path.name
    for candidate in (path, *path.parents):
        if candidate == Path.home():
            break
        if (candidate / '.git').exists():
            label = candidate.name
            break
    return validated_label(label)
