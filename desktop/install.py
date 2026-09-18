"""Per-user Omarchy installation. Runtime data and agent hooks are preserved."""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = "io.github.iamjamesim.paceman"
SERVICE = "paceman-source.service"


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


def migrate_database(source, target):
    """Only called after stopping the source; never replace an installed identity."""
    if target.exists() or not source.exists():
        return False
    directory(target.parent)
    fd, temporary = tempfile.mkstemp(dir=target.parent)
    os.close(fd)
    try:
        with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as old, closing(sqlite3.connect(temporary)) as new:
            old.backup(new)
            if new.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("Source database failed its integrity check")
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return True


def unit_escape(path):
    value = str(path)
    if any(ord(character) < 32 for character in value):
        raise ValueError("Installation paths cannot contain control characters")
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")


def render_unit(app, state):
    return (ROOT / "systemd/paceman-source.service").read_text().replace(
        "@APP@", unit_escape(app)).replace("@STATE@", unit_escape(state))


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
    try:
        for path in (app, ctl.parent, unit.parent, state):
            directory(path)
        if args.action == "uninstall":
            run("/usr/bin/systemctl", "--user", "disable", "--now", SERVICE, check=False)
            if plugin.exists():
                directory(plugin)
                run("/usr/bin/omarchy", "plugin", "disable", PLUGIN, check=False)
                shutil.rmtree(plugin)
            shutil.rmtree(app)
            ctl.unlink(missing_ok=True)
            unit.unlink(missing_ok=True)
            run("/usr/bin/systemctl", "--user", "daemon-reload")
            if Path("/usr/bin/omarchy").exists():
                run("/usr/bin/omarchy", "shell", "shell", "rescanPlugins", check=False)
            print("Paceman desktop removed. Pairings, data, Tailscale routes and agent hooks preserved.")
            return
        if sys.version_info < (3, 11):
            raise ValueError("Python 3.11 or later is required")
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
        # A manually launched source must be stopped by its owner before migrating.
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", 8765))
        if migrate_database(ROOT / ".runtime/hub.sqlite3", state / "hub.sqlite3"):
            print("Migrated the checkout's source identity and phone pairings; original database retained.")
        for package in ("service", "desktop"):
            for source in (ROOT / package).glob("*.py"):
                if source.name != "install.py":
                    write(app / package / source.name, source.read_bytes())
        write(ctl, (ROOT / "desktop/pacemanctl").read_bytes(), 0o755)
        write(unit, unit_content.encode())
        if not args.no_bar:
            for name in ("manifest.json", "BarWidget.qml", "PanelContent.qml", "PacemanMark.qml", "PanelModel.js", "PairingOverlay.qml"):
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
        print("Paceman updated; sharing remains off." if paused else
              "Paceman is running and starts at login. Open its bar panel or run pacemanctl status.")
        print("Existing Codex hooks are reused. See docs/desktop.md for first-time hook and Tailscale setup.")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        print(f"Paceman installation: {detail.strip()}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
