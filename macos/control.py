"""Local macOS control boundary for the menu-bar client and setup agent."""
from __future__ import annotations

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

from service.network import private_endpoint
from macos.codex_hook import EVENTS as CODEX_EVENTS, QUESTION_MATCHER
from service.hub import Store, endpoint
from macos.paths import installed_app

ROOT = Path.home() / "Library/Application Support/Paceman"
PLIST = Path.home() / "Library/LaunchAgents/ai.paceman.source.plist"
LABEL = "ai.paceman.source"


def missing_hooks(config_path: Path | None = None, script_path: Path | None = None) -> list[str]:
    config_path = config_path or Path.home() / ".codex/hooks.json"
    script_path = script_path or ROOT / "lib/macos/codex_hook.py"
    if not script_path.is_file():
        return list(CODEX_EVENTS)
    try:
        groups_by_event = json.loads(config_path.read_text()).get("hooks", {})
        if not isinstance(groups_by_event, dict):
            raise ValueError("Invalid hooks configuration")
    except (OSError, ValueError, AttributeError):
        return list(CODEX_EVENTS)

    def installed(item):
        if not isinstance(item, dict) or item.get("type") != "command":
            return False
        try:
            arguments = shlex.split(item.get("command", ""))
        except (TypeError, ValueError):
            return False
        return (len(arguments) in (2, 3) and arguments[-1] == str(script_path)
                and (len(arguments) == 2 or arguments[1] == "-B")
                and Path(arguments[0]).is_file())

    missing = []
    for event in CODEX_EVENTS:
        groups = groups_by_event.get(event, [])
        if not isinstance(groups, list) or not any(
            isinstance(group, dict) and isinstance(group.get("hooks"), list)
            and (event != "PreToolUse" or group.get("matcher") == QUESTION_MATCHER)
            and any(installed(item) for item in group["hooks"])
            for group in groups
        ):
            missing.append(event)
    return missing


def launch(*arguments):
    subprocess.run(["/bin/launchctl", *arguments], check=True, timeout=20)


def service_target():
    return f"gui/{os.getuid()}/{LABEL}"


def status():
    try:
        value = json.loads((ROOT / "status.json").read_text())
        if value.get("schema") != 1:
            raise ValueError("Unknown status")
    except (OSError, ValueError):
        value = {"schema": 1, "running": False, "clients": [], "activity": "idle", "sessions": 0}
    database = ROOT / "data/hub.sqlite3"
    if database.is_file():
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
            value["clients"] = Store.client_list(db)
    value["running"] = bool(value.get("running")) and 0 <= time.time() - value.get("updatedAt", 0) < 20
    value["sharingEnabled"] = not (ROOT / "sharing-paused").exists()
    value["computerName"] = socket.gethostname().split(".")[0]
    value["missingHooks"] = missing_hooks()
    try:
        arguments = plistlib.loads(PLIST.read_bytes()).get("ProgramArguments", [])
        if len(arguments) >= 2 and isinstance(arguments[1], str):
            value["hookCommand"] = (shlex.quote(arguments[1]) + " -B " +
                                    shlex.quote(str(ROOT / "lib/macos/codex_hook.py")))
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        pass
    return value


def sharing(enabled):
    marker = ROOT / "sharing-paused"
    was_paused = marker.exists()
    if enabled:
        marker.unlink(missing_ok=True)
    else:
        marker.write_text("paused\n")
        marker.chmod(0o600)
    try:
        if enabled:
            launch("enable", service_target())
            launch("bootstrap", f"gui/{os.getuid()}", str(PLIST))
        else:
            subprocess.run(["/bin/launchctl", "bootout", service_target()], timeout=20)
            launch("disable", service_target())
    except (OSError, subprocess.SubprocessError):
        if was_paused:
            marker.write_text("paused\n")
        else:
            marker.unlink(missing_ok=True)
        raise


def tailscale_binary():
    # Finder and login items do not inherit the user's shell PATH.
    candidates = (shutil.which("tailscale"), "/usr/local/bin/tailscale",
                  "/opt/homebrew/bin/tailscale",
                  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                  str(Path.home() / "Applications/Tailscale.app/Contents/MacOS/Tailscale"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise ValueError("Install Tailscale on this Mac, then follow Paceman’s Tailscale setup guide.")


def pairing():
    if not status()["running"]:
        raise ValueError("Start Paceman before connecting a phone")
    binary = tailscale_binary()
    try:
        route = subprocess.run([binary, "serve", "status", "--json"], check=True,
                               capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("Tailscale is unavailable. Open Tailscale, reconnect, then try again.") from error
    config = json.loads(route.stdout)
    try:
        origin = private_endpoint(config)
    except ValueError as error:
        raise ValueError("Tailscale isn’t set up for Paceman yet. Follow the Tailscale setup guide, then try again.") from error
    try:
        urllib.request.urlopen(origin + "/v1/snapshot", timeout=10).close()
    except urllib.error.HTTPError as error:
        error.close()
        if error.code != 401:
            raise ValueError("Tailscale can’t reach Paceman yet. Check the Tailscale setup guide, then try again.") from error
    except urllib.error.URLError as error:
        raise ValueError("Couldn’t connect to Paceman over Tailscale. Check that Tailscale is connected, then try again.") from error
    invitation = Store(ROOT / "data/hub.sqlite3").invite(endpoint(origin))
    print(json.dumps(invitation, separators=(",", ":")))


def remove_access(client_id):
    Store(ROOT / "data/hub.sqlite3").revoke(str(uuid.UUID(client_id)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "support", "pair", "share-on", "share-off", "restart", "remove-access", "uninstall"))
    parser.add_argument("--client-id")
    parser.add_argument("--yes", action="store_true", help="Confirm complete Mac uninstall")
    args = parser.parse_args()
    try:
        if args.command == "status":
            print(json.dumps(status(), separators=(",", ":")))
        elif args.command == "support":
            from macos.support import report
            app = installed_app()
            try:
                current_status = status()
            except sqlite3.Error:
                current_status = {"running": False, "sharingEnabled": not (ROOT / "sharing-paused").exists(),
                                  "missingHooks": missing_hooks()}
            print(json.dumps(report(ROOT, current_status, app), separators=(",", ":")))
        elif args.command == "pair":
            pairing()
        elif args.command in ("share-on", "share-off"):
            sharing(args.command == "share-on")
        elif args.command == "restart":
            launch("kickstart", "-k", service_target())
        elif args.command == "uninstall":
            if not args.yes:
                raise ValueError("Run pacemanctl uninstall --yes to remove the Mac app, hooks, pairings, and key")
            from macos.uninstall import uninstall
            print(uninstall())
        else:
            if not args.client_id:
                raise ValueError("Specify --client-id")
            remove_access(args.client_id)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Paceman: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
