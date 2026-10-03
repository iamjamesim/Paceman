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
PUSH_SERVICE = "paceman-push.service"
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


def render_unit(app, state, service=SERVICE):
    return (ROOT / "systemd" / service).read_text().replace(
        "@APP@", unit_escape(app)).replace("@STATE@", unit_escape(state))


def hook_command(app):
    return "/usr/bin/python3 -I " + shlex.quote(str(app / "omarchy/codex_hook.py"))


def owns_hook(item, app):
    if not isinstance(item, dict) or not isinstance(item.get("command"), str):
        return False
    try:
        return shlex.split(item["command"]) in (
            ["/usr/bin/python3", "-I", str(app / "omarchy/codex_hook.py")],
            ["/usr/bin/python3", "-I", str(app / "desktop/codex_hook.py")])
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
        modified = False
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                remaining.append(group)
                continue
            kept = []
            for item in group["hooks"]:
                if not owns_hook(item, app):
                    kept.append(item)
                elif remove or found:
                    modified = True
                else:
                    replacement = {**item, "command": hook_command(app)}
                    kept.append(replacement)
                    modified |= replacement != item
                    found = True
            if kept or not remove:
                remaining.append({**group, "hooks": kept})
        if not remove and not found:
            remaining.append({"hooks": [{"type": "command",
                "command": hook_command(app), "timeout": 3}]})
            modified = True
        if modified:
            hooks[event] = remaining
            changed.append(event)
    return document, changed


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "uninstall"))
    parser.add_argument("--no-bar", action="store_true", help="Install the daemon without an Omarchy widget")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--relay-url", help="Use a self-hosted relay instead of the Paceman relay")
    selection.add_argument("--no-push-setup", action="store_true",
                           help="Skip automatic relay setup for a developer-managed sender")
    args = parser.parse_args()
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    state = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "paceman"
    app = home / ".local/lib/paceman"
    ctl = home / ".local/bin/pacemanctl"
    unit = config / "systemd/user" / SERVICE
    push_unit = config / "systemd/user" / PUSH_SERVICE
    plugin = config / "omarchy/plugins" / PLUGIN
    hooks_path = home / ".codex/hooks.json"
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    try:
        for path in (app, ctl.parent, unit.parent, state):
            directory(path)
        if args.action == "uninstall":
            from service.network import remove_owned_route
            hooks_document, changed_hooks = hook_document(hooks_path, app, remove=True)
            run("/usr/bin/systemctl", "--user", "disable", "--now", SERVICE, check=False)
            run("/usr/bin/systemctl", "--user", "disable", "--now", PUSH_SERVICE, check=False)
            if plugin.exists():
                directory(plugin)
                run("/usr/bin/omarchy", "plugin", "disable", PLUGIN, check=False)
                shutil.rmtree(plugin)
            if changed_hooks:
                write(hooks_path, (json.dumps(hooks_document, indent=2) + "\n").encode(), 0o600)
            shutil.rmtree(app)
            ctl.unlink(missing_ok=True)
            unit.unlink(missing_ok=True)
            push_unit.unlink(missing_ok=True)
            run("/usr/bin/systemctl", "--user", "daemon-reload")
            route_removed = remove_owned_route(state)
            if Path("/usr/bin/omarchy").exists():
                run("/usr/bin/omarchy", "shell", "shell", "rescanPlugins", check=False)
            print("Paceman Omarchy source and its Codex hooks removed. Pairings, data, and unrelated hooks preserved.")
            if route_removed:
                print("Paceman's private Tailscale route removed.")
            elif (state / "tailscale-route.json").exists():
                print("Paceman's private Tailscale route could not be removed; check Tailscale Serve settings.")
            return
        if sys.version_info < (3, 11):
            raise ValueError("Python 3.11 or later is required")
        # The install script is launched with -I, which omits the checkout root.
        from service.hub import Store, endpoint
        from service.push import Config, DEFAULT_RELAY_URL, RelayConfig
        from service.network import RouteSetupError, ensure_private_route
        relay_url = endpoint(args.relay_url or DEFAULT_RELAY_URL)
        directory(hooks_path.parent)
        hooks_document, changed_hooks = hook_document(hooks_path, app)
        run("/usr/bin/systemctl", "--user", "show-environment")
        if not args.no_bar:
            run("/usr/bin/omarchy", "plugin", "validate", str(ROOT / "omarchy/plugin"))
            run("/usr/bin/omarchy", "shell", "shell", "ping")
            directory(plugin)
        # Validate code before stopping an existing installation.
        run("/usr/bin/python3", "-I", str(ROOT / "service/launch.py"), "--help")
        unit_content = render_unit(app, state)
        push_unit_content = render_unit(app, state, PUSH_SERVICE)
        started_install = time.time()
        run("/usr/bin/systemctl", "--user", "stop", SERVICE, check=False)
        run("/usr/bin/systemctl", "--user", "disable", "--now", "omarchy-watch.service", check=False)
        if (config / "omarchy/plugins/io.github.iamjamesim.omarchy-watch").exists():
            run("/usr/bin/omarchy", "plugin", "disable", "io.github.iamjamesim.omarchy-watch")
        # A manually launched source must be stopped by its owner before installation.
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", 8765))
        for package in ("service", "omarchy"):
            for source in (ROOT / package).glob("*.py"):
                if source.name != "install.py":
                    write(app / package / source.name, source.read_bytes())
        for name in ("CODEX_HOOK_UPSTREAM.md", "OMARCHY_WATCH_CODEX_LICENSE"):
            write(app / "omarchy" / name, (ROOT / "omarchy" / name).read_bytes())
        write(ctl, (ROOT / "omarchy/pacemanctl").read_bytes(), 0o755)
        write(unit, unit_content.encode())
        write(push_unit, push_unit_content.encode())
        notification_error = None
        relay_setup_attempted = False
        push_config = state / "private/apns.json"
        if not args.no_push_setup and (args.relay_url or not push_config.is_file()):
            relay_setup_attempted = True
            try:
                from omarchy import install_push
                Store(state / "hub.sqlite3")
                install_push.configure(relay_url, app=app, state=state, restart=False, announce=False)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                notification_error = str(error)
        elif push_config.is_file():
            try:
                raw = json.loads(push_config.read_text())
                if isinstance(raw, dict) and "relayURL" in raw:
                    relay = RelayConfig.load(raw)
                    if relay.source_id != Store(state / "hub.sqlite3").metadata("source_id"):
                        raise ValueError("Relay source ID does not match this installation")
                else:
                    Config.load(push_config)
                if not (state / "push-venv/bin/python3").is_file():
                    raise ValueError("Push worker environment is missing")
                print("Existing iPhone notification configuration preserved.")
            except (OSError, ValueError, TypeError) as error:
                notification_error = f"Existing push configuration needs repair: {error}"
        else:
            print("Notification setup skipped as requested. Configure a relay before pairing a phone.")
        if not args.no_bar:
            for name in ("manifest.json", "BarWidget.qml", "PanelContent.qml", "ConnectionRow.qml", "PacemanMark.qml", "PanelModel.js", "PairingOverlay.qml"):
                write(plugin / name, (ROOT / "omarchy/plugin" / name).read_bytes())
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
            if push_config.is_file() and not notification_error:
                for attempt in range(20):
                    if run("/usr/bin/systemctl", "--user", "is-active", PUSH_SERVICE,
                           check=False).stdout.strip() == "active":
                        break
                    time.sleep(.25)
                else:
                    notification_error = "Paceman push sender did not start. Run pacemanctl logs."
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
        legacy = app / "desktop"
        if legacy.is_dir() and not legacy.is_symlink():
            shutil.rmtree(legacy)
        route_error = None
        if not paused:
            try:
                ensure_private_route(state)
                print("Private phone connection ready through Tailscale.")
            except RouteSetupError as error:
                route_error = str(error)
        print("Paceman updated; sharing remains off." if paused else
              "Paceman is running and starts at login. Open its bar panel or run pacemanctl status.")
        print("Review Paceman's Codex hooks with /hooks; Codex calls each entry Hook 1.")
        print("Command:", hook_command(app))
        for event, purpose in HOOK_PURPOSES:
            print(f"  {event}: {purpose}")
        print("After review, run a fresh local task and check lastAgentEventAt in pacemanctl status.")
        if route_error:
            print(f"Phone connection setup is incomplete: {route_error}", file=sys.stderr)
            print("Complete the Tailscale step, then use the panel's pairing button to retry.", file=sys.stderr)
        if notification_error:
            print(f"Paceman source is installed, but notification setup is incomplete: {notification_error}",
                  file=sys.stderr)
            if relay_setup_attempted:
                print(f"Retry from this checkout: /usr/bin/python3 -m omarchy.install_push "
                      f"--relay-url {shlex.quote(relay_url)}", file=sys.stderr)
            else:
                print(f"Inspect the preserved configuration at {push_config}.", file=sys.stderr)
        if push_config.is_file() and not notification_error:
            print("iPhone notification sender configured. Pair with a fresh QR code if this phone was paired before relay setup.")
        if route_error or notification_error:
            raise SystemExit(2)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        print(f"Paceman installation: {detail.strip()}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
