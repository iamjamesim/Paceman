"""Remove owned response hooks; native connections supply remote answers."""
from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import shlex


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
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ValueError(f"Invalid {provider} {event} hooks")
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept.append(group)
                continue
            items = [item for item in group["hooks"] if not owns_hook(item, root, provider)]
            if items == group["hooks"]:
                kept.append(group)
            elif items:
                kept.append({**group, "hooks": items})
        hooks[event] = kept
    return result
