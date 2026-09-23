"""Remove this Mac's Paceman installation without touching other Codex hooks."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile

from macos.install import APP, LABEL, PLIST, PUSH_LABEL, PUSH_PLIST, ROOT

HOOKS = Path.home() / ".codex/hooks.json"


def cleaned_hooks(path: Path | None = None):
    path = path or HOOKS
    if not path.exists():
        return None
    document = json.loads(path.read_text())
    if not isinstance(document, dict) or not isinstance(document.get("hooks", {}), dict):
        raise ValueError("Codex hooks configuration is invalid; leave it for manual review")
    changed = False
    script = str(ROOT / "lib/macos/codex_hook.py")
    for event, groups in document.get("hooks", {}).items():
        if not isinstance(groups, list):
            raise ValueError(f"Codex {event} hooks are invalid; leave them for manual review")
        remaining = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                remaining.append(group)
                continue
            kept = []
            for hook in group["hooks"]:
                try:
                    arguments = shlex.split(hook.get("command", "")) if isinstance(hook, dict) else []
                except (TypeError, ValueError):
                    arguments = []
                if len(arguments) == 2 and arguments[1] == script:
                    changed = True
                else:
                    kept.append(hook)
            if kept:
                remaining.append({**group, "hooks": kept})
        document["hooks"][event] = remaining
    return document if changed else None


def uninstall():
    if ROOT.is_symlink() or (ROOT.exists() and ROOT.stat().st_uid != os.getuid()):
        raise ValueError("Paceman data directory is not owned by this user")
    if APP.exists():
        info = APP / "Contents/Info.plist"
        if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != "dev.paceman.macos":
            raise ValueError("The app at the Paceman path is not Paceman")
    for path, label in ((PLIST, LABEL), (PUSH_PLIST, PUSH_LABEL)):
        if path.exists() and plistlib.loads(path.read_bytes()).get("Label") != label:
            raise ValueError(f"Background item at {path} does not belong to Paceman")
    hooks = cleaned_hooks()

    login_command = APP / "Contents/MacOS/Paceman"
    if login_command.is_file():
        subprocess.run([str(login_command), "--unregister-login"], check=True,
                       capture_output=True, text=True, timeout=20)

    for path, label in ((PLIST, LABEL), (PUSH_PLIST, PUSH_LABEL)):
        if path.exists():
            subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
            path.unlink()
    if hooks is not None:
        descriptor, name = tempfile.mkstemp(prefix=".paceman-hooks-", dir=HOOKS.parent)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "w") as output:
                json.dump(hooks, output, indent=2)
                output.write("\n")
            temporary.replace(HOOKS)
        finally:
            temporary.unlink(missing_ok=True)
    if APP.exists():
        shutil.rmtree(APP)
    if ROOT.exists():
        shutil.rmtree(ROOT)
    return ("Removed Paceman's Mac app, background item, Codex hooks, local pairings, "
            "and APNs key. The iPhone app, Python, and Tailscale remain installed.")
