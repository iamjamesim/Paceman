"""Explicit, reversible setup for synchronous phone responses; never grants trust."""
from __future__ import annotations

from copy import deepcopy
import json
import os
from pathlib import Path
import shlex
import stat
import tempfile

from macos.agents import PROVIDERS, configured_providers, hook_path
from service.interactions import RESPONSE_TIMEOUT_SECONDS


def enabled(root: Path) -> bool:
    marker = root / "responses-enabled"
    try:
        return (not marker.is_symlink() and marker.is_file()
                and marker.stat().st_uid == os.getuid() and marker.read_bytes() == b"enabled\n")
    except OSError:
        return False


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


def updated_hooks(document, root: Path, python: str, provider: str, active: bool):
    """Keep observer and foreign definitions intact, including their matchers."""
    if not isinstance(document, dict) or not isinstance(document.get("hooks", {}), dict):
        raise ValueError(f"Invalid {provider} hooks configuration")
    if active and document.get("disableAllHooks") is True:
        raise ValueError(f"{provider} has disableAllHooks enabled; review that setting yourself")
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
    if active:
        events = [("PermissionRequest", None)]
        events.append(("PreToolUse", "^AskUserQuestion$" if provider == "claude"
                       else "^request_user_input(_async)?$"))
        for event, matcher in events:
            group = {"hooks": [{"type": "command", "command": command(root, python, provider),
                                "timeout": RESPONSE_TIMEOUT_SECONDS + 5}]}
            if matcher:
                group["matcher"] = matcher
            hooks.setdefault(event, []).append(group)
    return result


def _write(path: Path, data: bytes | None, mode=0o600):
    if data is None:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=".paceman-responses-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
        Path(name).replace(path)
    finally:
        Path(name).unlink(missing_ok=True)


def restore(changes):
    for path, original, mode in reversed(changes):
        _write(path, original, mode)


def configure(root: Path, python: str, active: bool):
    """Validate all files first, then atomically replace each with rollback."""
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
        raise ValueError("Paceman must be installed in a directory owned by this user")
    if active and root.stat().st_mode & 0o077:
        raise ValueError("Paceman's data directory must be private to this user")
    providers = configured_providers(root)
    if active and not providers:
        raise ValueError("Select an agent before enabling phone responses")
    targets = []
    for provider in PROVIDERS:
        target = hook_path(provider, root=root)
        if target.is_symlink() or target.exists() and target.stat().st_uid != os.getuid():
            raise ValueError(f"Review {provider} settings ownership before changing response hooks")
        original = target.read_bytes() if target.exists() else None
        if original is None and (not active or provider not in providers):
            continue
        document = json.loads(original) if original is not None else {}
        updated = updated_hooks(document, root, python, provider, active and provider in providers)
        if updated == document:
            continue
        mode = stat.S_IMODE(target.stat().st_mode) if original is not None else 0o600
        targets.append((target, original, mode, (json.dumps(updated, indent=2) + "\n").encode()))
    marker = root / "responses-enabled"
    if marker.is_symlink():
        raise ValueError("Response setting must not be a symbolic link")
    original = marker.read_bytes() if marker.exists() else None
    desired = b"enabled\n" if active else None
    if original != desired:
        targets.append((marker, original, 0o600, desired))
    changed = []
    try:
        for path, original, mode, data in targets:
            _write(path, data, mode)
            changed.append((path, original, mode))
    except Exception:
        restore(changed)
        raise
    return changed
