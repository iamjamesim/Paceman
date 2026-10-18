"""Response hook definitions prepared by normal agent setup; never grants trust."""
from __future__ import annotations

from copy import deepcopy
import os
from pathlib import Path
import shlex
from service.interactions import RESPONSE_TIMEOUT_SECONDS


def command(root: Path, python: str, provider: str) -> str:
    return shlex.join([python, "-B", str(root / "lib/macos/interaction_hook.py"),
                       "--provider", provider])


def owns_hook(item, root: Path, provider: str) -> bool:
    if not isinstance(item, dict):
        return False
    try:
        args = shlex.split(item.get("command", ""))
    except (TypeError, ValueError):
        return False
    return (len(args) == 5 and args[1:] == ["-B", str(root / "lib/macos/interaction_hook.py"),
                                           "--provider", provider])


def updated_hooks(document, root: Path, python: str, provider: str):
    """Keep observer and foreign definitions intact, including their matchers."""
    if not isinstance(document, dict) or not isinstance(document.get("hooks", {}), dict):
        raise ValueError(f"Invalid {provider} hooks configuration")
    result = deepcopy(document)
    hooks = result.setdefault("hooks", {})
    commands = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ValueError(f"Invalid {provider} {event} hooks")
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept.append(group)
                continue
            items = []
            for item in group["hooks"]:
                if not owns_hook(item, root, provider):
                    items.append(item)
                    continue
                interpreter = Path(shlex.split(item["command"])[0])
                if interpreter.is_absolute() and interpreter.is_file() and os.access(interpreter, os.X_OK):
                    commands.setdefault(event, item["command"])
            if items == group["hooks"]:
                kept.append(group)
            elif items:
                kept.append({**group, "hooks": items})
        hooks[event] = kept
    for event, matcher in (("PermissionRequest", None),
            ("PreToolUse", "^AskUserQuestion$" if provider == "claude" else "^request_user_input(_async)?$")):
        group = {"hooks": [{"type": "command", "command": commands.get(event, command(root, python, provider)),
                            "timeout": RESPONSE_TIMEOUT_SECONDS + 5}]}
        if matcher:
            group["matcher"] = matcher
        hooks.setdefault(event, []).append(group)
    return result
