"""Remove this Mac's Paceman installation without touching other agent hooks or settings."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import tempfile

from service.push import revoke_relay_source
from service.network import remove_owned_route

from macos.agents import hook_path
from macos.install import APP, LABEL, PLIST, PUSH_LABEL, PUSH_PLIST, ROOT

HOOKS = Path.home() / ".codex/hooks.json"


def cleaned_hooks(path: Path | None = None, *, provider="codex"):
    path = path or (HOOKS if provider == "codex" else hook_path(provider))
    if not path.exists():
        return None
    document = json.loads(path.read_text())
    if not isinstance(document, dict) or not isinstance(document.get("hooks", {}), dict):
        raise ValueError("Agent hooks configuration is invalid; leave it for manual review")
    changed = False
    script = str(ROOT / f"lib/macos/{provider}_hook.py")
    for event, groups in document.get("hooks", {}).items():
        if not isinstance(groups, list):
            raise ValueError(f"Agent {event} hooks are invalid; leave them for manual review")
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
                if len(arguments) in (2, 3) and arguments[-1] == script:
                    changed = True
                else:
                    kept.append(hook)
            if kept:
                remaining.append({**group, "hooks": kept})
        document["hooks"][event] = remaining
    return document if changed else None


def stop_menu_app(executable: Path) -> None:
    """Close only this user's installed Paceman menu process."""
    if not executable.is_file():
        return
    # Match the executable, not the full command line: setup adds --show-setup.
    result = subprocess.run(["/bin/ps", "-axo", "pid=,uid=,comm="], check=True,
                            capture_output=True, text=True, timeout=5)
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3 or fields[2] != str(executable):
            continue
        pid, uid = map(int, fields[:2])
        if uid != os.getuid() or pid == os.getppid():
            # A menu-initiated uninstall closes its parent after reporting success.
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


def uninstall():
    if ROOT.is_symlink() or (ROOT.exists() and ROOT.stat().st_uid != os.getuid()):
        raise ValueError("Paceman data directory is not owned by this user")
    if APP.exists():
        info = APP / "Contents/Info.plist"
        if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != "ai.paceman.macos":
            raise ValueError("The app at the Paceman path is not Paceman")
    for path, label in ((PLIST, LABEL), (PUSH_PLIST, PUSH_LABEL)):
        if path.exists() and plistlib.loads(path.read_bytes()).get("Label") != label:
            raise ValueError(f"Background item at {path} does not belong to Paceman")
    hooks = cleaned_hooks()
    claude_path = hook_path("claude", root=ROOT)
    claude_hooks = cleaned_hooks(claude_path, provider="claude")

    login_command = APP / "Contents/MacOS/Paceman"
    if login_command.is_file():
        subprocess.run([str(login_command), "--unregister-login"], check=True,
                       capture_output=True, text=True, timeout=20)
    stop_menu_app(login_command)

    for path, label in ((PLIST, LABEL), (PUSH_PLIST, PUSH_LABEL)):
        if path.exists():
            subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
            path.unlink()
    relay_revocation_pending = revoke_relay_source(ROOT / "private/apns.json")
    route_recorded = (ROOT / "tailscale-route.json").exists()
    route_removed = remove_owned_route(ROOT)
    for path, document in ((HOOKS, hooks), (claude_path, claude_hooks)):
        if document is None:
            continue
        descriptor, name = tempfile.mkstemp(prefix=".paceman-hooks-", dir=path.parent)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "w") as output:
                json.dump(document, output, indent=2)
                output.write("\n")
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    if APP.exists():
        shutil.rmtree(APP)
    if ROOT.exists():
        shutil.rmtree(ROOT)
    result = ("Removed Paceman's Mac app, background item, Paceman hooks, local pairings, "
              "and APNs key. The iPhone app, other Python installations, and Tailscale remain installed.")
    if relay_revocation_pending:
        result += (" Relay revocation could not be confirmed for source " + relay_revocation_pending
                   + "; ask the project owner to revoke it in the relay database.")
    if route_recorded and not route_removed:
        result += " Check Tailscale Serve settings; Paceman's route could not be removed."
    return result
