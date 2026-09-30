"""Per-user Omarchy installation with reviewed Paceman Codex hooks."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = "io.github.iamjamesim.paceman"
SERVICE = "paceman-source.service"
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


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=30)


def directory(path):
    """Refuse symlink destinations or directories writable by other users."""
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Use an absolute destination: {path}")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ValueError(f"Refusing a symbolic-link destination: {current}")
        current.mkdir(mode=0o700, exist_ok=True)
        info = current.stat()
        if not stat.S_ISDIR(info.st_mode) or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
            raise ValueError(f"Unsafe destination directory: {current}")
    if path.stat().st_uid != os.getuid():
        raise ValueError(f"Destination is not owned by you: {path}")


def write(path, data, mode=0o644):
    directory(path.parent)
    if path.is_symlink():
        raise ValueError(f"Refusing a symbolic-link file: {path}")
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def unit_escape(path):
    value = str(path)
    if any(ord(character) < 32 for character in value):
        raise ValueError("Installation paths cannot contain control characters")
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")


def render_unit(app, state):
    return (ROOT / "systemd/paceman-source.service").read_text().replace(
        "@APP@", unit_escape(app)).replace("@STATE@", unit_escape(state))


def hook_command(app):
    return "/usr/bin/python3 -I " + shlex.quote(str(app / "desktop/codex_hook.py"))


def owns_hook(item, app):
    if not isinstance(item, dict) or not isinstance(item.get("command"), str):
        return False
    try:
        return shlex.split(item["command"]) == [
            "/usr/bin/python3", "-I", str(app / "desktop/codex_hook.py")]
    except ValueError:
        return False


def hook_document(path, app, *, remove=False):
    """Return a changed hooks document without touching unrelated entries."""
    if path.is_symlink():
        raise ValueError("Refusing a symbolic-link Codex hooks file")
    document = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(document, dict):
        raise ValueError("Existing ~/.codex/hooks.json is not a JSON object")
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing Codex hooks configuration is not an object")
    changed = []
    for event in (tuple(hooks) if remove else HOOK_EVENTS):
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            raise ValueError(f"Existing {event} hooks are not a list")
        remaining = []
        found = False
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                remaining.append(group)
                continue
            kept = [item for item in group["hooks"] if not owns_hook(item, app)]
            if len(kept) != len(group["hooks"]):
                found = True
            if remove:
                if kept:
                    remaining.append({**group, "hooks": kept})
            else:
                remaining.append(group)
        if remove:
            if found:
                hooks[event] = remaining
                changed.append(event)
        elif not found:
            hooks.setdefault(event, groups).append({"hooks": [{"type": "command",
                "command": hook_command(app), "timeout": 3}]})
            changed.append(event)
    return document, changed


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "uninstall"))
    parser.add_argument("--no-bar", action="store_true", help="Install the daemon without an Omarchy widget")
    args = parser.parse_args()
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    state = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "paceman"
    app = home / ".local/lib/paceman"
    ctl = home / ".local/bin/pacemanctl"
    unit = config / "systemd/user" / SERVICE
    plugin = config / "omarchy/plugins" / PLUGIN
    hooks_path = home / ".codex/hooks.json"
    try:
        for path in (app, ctl.parent, unit.parent, state):
            directory(path)
        if args.action == "uninstall":
            hooks_document, changed_hooks = hook_document(hooks_path, app, remove=True)
            run("/usr/bin/systemctl", "--user", "disable", "--now", SERVICE, check=False)
            if plugin.exists():
                directory(plugin)
                run("/usr/bin/omarchy", "plugin", "disable", PLUGIN, check=False)
                shutil.rmtree(plugin)
            if changed_hooks:
                write(hooks_path, (json.dumps(hooks_document, indent=2) + "\n").encode(), 0o600)
            shutil.rmtree(app)
            ctl.unlink(missing_ok=True)
            unit.unlink(missing_ok=True)
            run("/usr/bin/systemctl", "--user", "daemon-reload")
            if Path("/usr/bin/omarchy").exists():
                run("/usr/bin/omarchy", "shell", "shell", "rescanPlugins", check=False)
            print("Paceman desktop and its Codex hooks removed. Pairings, data, Tailscale routes and unrelated hooks preserved.")
            return
        if sys.version_info < (3, 11):
            raise ValueError("Python 3.11 or later is required")
        directory(hooks_path.parent)
        hooks_document, changed_hooks = hook_document(hooks_path, app)
        run("/usr/bin/systemctl", "--user", "show-environment")
        if not args.no_bar:
            run("/usr/bin/omarchy", "plugin", "validate", str(ROOT / "desktop/plugin"))
            run("/usr/bin/omarchy", "shell", "shell", "ping")
            directory(plugin)
        # Validate code before stopping an existing installation.
        run("/usr/bin/python3", "-I", str(ROOT / "desktop/launch.py"), "--help")
        unit_content = render_unit(app, state)
        started_install = time.time()
        run("/usr/bin/systemctl", "--user", "stop", SERVICE, check=False)
        run("/usr/bin/systemctl", "--user", "disable", "--now", "omarchy-watch.service", check=False)
        if (config / "omarchy/plugins/io.github.iamjamesim.omarchy-watch").exists():
            run("/usr/bin/omarchy", "plugin", "disable", "io.github.iamjamesim.omarchy-watch")
        # A manually launched source must be stopped by its owner before installation.
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", 8765))
        for package in ("service", "desktop"):
            for source in (ROOT / package).glob("*.py"):
                if source.name != "install.py":
                    write(app / package / source.name, source.read_bytes())
        for name in ("CODEX_HOOK_UPSTREAM.md", "OMARCHY_WATCH_CODEX_LICENSE"):
            write(app / "desktop" / name, (ROOT / "desktop" / name).read_bytes())
        write(ctl, (ROOT / "desktop/pacemanctl").read_bytes(), 0o755)
        write(unit, unit_content.encode())
        if not args.no_bar:
            for name in ("manifest.json", "BarWidget.qml", "PanelContent.qml", "ConnectionRow.qml", "PacemanMark.qml", "PanelModel.js", "PairingOverlay.qml"):
                write(plugin / name, (ROOT / "desktop/plugin" / name).read_bytes())
        run("/usr/bin/systemctl", "--user", "daemon-reload")
        paused = (state / "sharing-paused").exists()
        if paused:
            run("/usr/bin/systemctl", "--user", "disable", "--now", SERVICE)
        else:
            run("/usr/bin/systemctl", "--user", "enable", "--now", SERVICE)
            for attempt in range(40):
                status = json.loads(run(str(ctl), "status").stdout)
                if status.get("running") and status.get("startedAt", 0) >= started_install:
                    break
                time.sleep(.25)
            else:
                raise ValueError("Paceman did not become ready. Run pacemanctl logs.")
        if not args.no_bar:
            shell_config = config / "omarchy/shell.json"
            if shell_config.exists():
                backup = shell_config.with_name(f"shell.json.before-paceman-{time.time_ns()}")
                write(backup, shell_config.read_bytes(), 0o600)
            run("/usr/bin/omarchy", "shell", "shell", "rescanPlugins")
            # Empty placement preserves an existing location on upgrades.
            run("/usr/bin/omarchy", "plugin", "enable", PLUGIN)
            # QML components are cached; rescanning alone does not load upgrades.
            run("/usr/bin/omarchy", "restart", "shell")
        if changed_hooks:
            write(hooks_path, (json.dumps(hooks_document, indent=2) + "\n").encode(), 0o600)
        print("Paceman updated; sharing remains off." if paused else
              "Paceman is running and starts at login. Open its bar panel or run pacemanctl status.")
        print("Review Paceman's Codex hooks with /hooks; Codex calls each entry Hook 1.")
        print("Command:", hook_command(app))
        for event, purpose in HOOK_PURPOSES:
            print(f"  {event}: {purpose}")
        print("After review, run a fresh local task and check lastAgentEventAt in pacemanctl status.")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        print(f"Paceman installation: {detail.strip()}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
