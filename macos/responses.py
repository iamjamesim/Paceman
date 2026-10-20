"""Migrate interceptors to Claude permission competition; Codex uses a follower."""
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
    retained = None
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ValueError(f"Invalid {provider} {event} hooks")
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept.append(group)
                continue
            if provider == "claude" and event == "PermissionRequest":
                for item in group["hooks"]:
                    if owns_hook(item, root, provider):
                        args = shlex.split(item["command"])
                        if Path(args[0]).is_file():
                            retained = item["command"]
            items = [item for item in group["hooks"] if not owns_hook(item, root, provider)]
            if items == group["hooks"]:
                kept.append(group)
            elif items:
                kept.append({**group, "hooks": items})
        hooks[event] = kept
    if provider == "claude":
        hooks.setdefault("PermissionRequest", []).append({"hooks": [{"type": "command",
            "command": retained or command(root, python, provider), "timeout": 605}]})
    return result
