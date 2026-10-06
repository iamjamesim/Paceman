"""Local provider choices and Paceman-owned hooks; no credentials or quotas."""
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil

from service.claude_hooks import EVENTS as CLAUDE_EVENTS, CLAUDE_PURPOSES
from omarchy.files import directory, write

PROVIDERS = ("codex", "claude")
HOOK_PURPOSES = (
    ("UserPromptSubmit", "show new work"),
    ("PreToolUse", "track tool calls and input questions"),
    ("PermissionRequest", "show approval needed"),
    ("PostToolUse", "clear resolved blocking questions and approvals"),
    ("Stop", "show a finished turn"),
    ("Interrupt", "clear an interrupted turn"),
    ("SessionEnd", "remove a closed session"),
)
HOOK_EVENTS = tuple(event for event, _ in HOOK_PURPOSES)


def hook_command(app, provider="codex"):
    return "/usr/bin/python3 -I " + shlex.quote(str(app / f"omarchy/{provider}_hook.py"))


def owns_hook(item, app, provider="codex"):
    if not isinstance(item, dict) or not isinstance(item.get("command"), str):
        return False
    try:
        return shlex.split(item["command"]) in (
            ["/usr/bin/python3", "-I", str(app / f"omarchy/{provider}_hook.py")],
            ["/usr/bin/python3", "-I", str(app / f"desktop/{provider}_hook.py")])
    except ValueError:
        return False


def hook_document(path, app, *, remove=False, provider="codex"):
    """Return a changed hooks document without touching unrelated entries."""
    if path.is_symlink():
        raise ValueError("Refusing a symbolic-link agent hooks file")
    document = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(document, dict):
        raise ValueError("Existing agent settings file is not a JSON object")
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing agent hooks configuration is not an object")
    changed = []
    for event in (tuple(hooks) if remove else (HOOK_EVENTS if provider == "codex" else CLAUDE_EVENTS)):
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            raise ValueError(f"Existing {event} hooks are not a list")
        remaining = []
        found = False
        modified = False
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                remaining.append(group)
                continue
            kept = []
            for item in group["hooks"]:
                if not owns_hook(item, app, provider):
                    kept.append(item)
                elif remove or found or (provider == "claude" and group.get("matcher", "") not in ("", "*")):
                    modified = True
                else:
                    replacement = {**item, "command": hook_command(app, provider)}
                    kept.append(replacement)
                    modified |= replacement != item
                    found = True
            if kept or not remove:
                remaining.append({**group, "hooks": kept})
        if not remove and not found:
            remaining.append({"hooks": [{"type": "command",
                "command": hook_command(app, provider), "timeout": 3}]})
            modified = True
        if modified:
            hooks[event] = remaining
            changed.append(event)
    return document, changed


def configuration(root):
    path = root / "agents.json"
    if path.is_symlink():
        raise ValueError("Refusing a symbolic-link agent configuration")
    if not path.exists():
        return {"providers": ["codex"], "claudeConfigDir": str(Path(os.environ.get(
            "CLAUDE_CONFIG_DIR", Path.home() / ".claude")).expanduser().absolute())}
    value = json.loads(path.read_text())
    if (not isinstance(value, dict) or not isinstance(value.get("providers"), list)
            or any(p not in PROVIDERS for p in value["providers"])
            or not isinstance(value.get("claudeConfigDir"), str)
            or not Path(value["claudeConfigDir"]).is_absolute()):
        raise ValueError("Invalid Paceman agent configuration")
    return value


def configured_providers(root):
    return configuration(root)["providers"]


def hook_paths(root, *, home=None):
    home = home or Path.home()
    return {"codex": home / ".codex/hooks.json",
            "claude": Path(configuration(root)["claudeConfigDir"]) / "settings.json"}


def detected_providers(root, *, home=None):
    home = home or Path.home()
    result = [p for p in PROVIDERS if shutil.which(p) or
              ((home / ".local/bin" / p).is_file() and os.access(home / ".local/bin" / p, os.X_OK))]
    if "claude" not in result and any(any((home / editor / "extensions").glob("anthropic.claude-code-*"))
            for editor in (".vscode", ".vscode-insiders", ".cursor", ".windsurf", ".vscode-server")):
        result.append("claude")
    return result


def prepare(root, app, providers, *, home=None):
    if any(p not in PROVIDERS for p in providers):
        raise ValueError("Unknown agent provider")
    providers = [p for p in PROVIDERS if p in providers]
    config = {**configuration(root), "providers": providers}
    documents = []
    for provider, path in hook_paths(root, home=home).items():
        document, changed = hook_document(path, app, provider=provider, remove=provider not in providers)
        if changed:
            directory(path.parent)
            documents.append((path, (json.dumps(document, indent=2) + "\n").encode()))
    documents.append((root / "agents.json", (json.dumps(config, indent=2) + "\n").encode()))
    return documents


def apply(documents):
    """Restore previous files if any write fails; validate everything before this."""
    originals = [(path, path.read_bytes() if path.exists() else None,
                  path.stat().st_mode & 0o777 if path.exists() else 0o600) for path, _ in documents]
    written = []
    try:
        for (path, data), original in zip(documents, originals):
            write(path, data, 0o600)
            written.append(original)
    except (OSError, ValueError):
        for path, data, mode in reversed(written):
            if data is None:
                path.unlink(missing_ok=True)
            else:
                write(path, data, mode)
        raise


def configure(root, app, *, enable=None, disable=None, home=None):
    if any(p is not None and p not in PROVIDERS for p in (enable, disable)):
        raise ValueError("Unknown agent provider")
    directory(root)
    fd = os.open(root / "agents.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        providers = set(configured_providers(root))
        if enable:
            providers.add(enable)
        if disable:
            providers.discard(disable)
        if enable or disable:
            apply(prepare(root, app, providers, home=home))
        return [p for p in PROVIDERS if p in providers]
