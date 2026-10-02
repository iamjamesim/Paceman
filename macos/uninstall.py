"""Remove this Mac's Paceman installation without touching other Codex hooks."""
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
from urllib.request import Request, build_opener, HTTPRedirectHandler

from service.push import RelayConfig

from macos.install import APP, LABEL, PLIST, PUSH_LABEL, PUSH_PLIST, ROOT

HOOKS = Path.home() / ".codex/hooks.json"


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


def revoke_relay_source(config_path: Path) -> str | None:
    """Return the source ID only when remote revocation cannot be confirmed."""
    if not config_path.is_file():
        return None
    value = None
    try:
        value = json.loads(config_path.read_text())
        if not isinstance(value, dict) or "relayURL" not in value:
            return None
        config = RelayConfig.load(value)
        request = Request(config.url + "/v2/sources",
            data=json.dumps({"sourceID": config.source_id}).encode(), method="DELETE",
            headers={"Authorization": "Bearer " + config.credential,
                     "Content-Type": "application/json"})
        with build_opener(_NoRedirect()).open(request, timeout=5) as response:
            return None if response.status == 200 else config.source_id
    except Exception:
        return value.get("sourceID", "unknown") if isinstance(value, dict) else "unknown"


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
    result = subprocess.run(["/usr/bin/pgrep", "-U", str(os.getuid()),
                             "-f", "-x", str(executable)],
                            capture_output=True, text=True, timeout=5)
    if result.returncode == 1:  # The menu app was not open.
        return
    if result.returncode != 0:
        raise OSError("Could not close the Paceman menu app")
    for value in result.stdout.splitlines():
        pid = int(value)
        if pid == os.getppid():
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
    result = ("Removed Paceman's Mac app, background item, Codex hooks, local pairings, "
              "and APNs key. The iPhone app, other Python installations, and Tailscale remain installed.")
    if relay_revocation_pending:
        result += (" Relay revocation could not be confirmed for source " + relay_revocation_pending
                   + "; ask the project owner to revoke it in the relay database.")
    return result
