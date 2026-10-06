"""Small command boundary for the Paceman bar panel and terminal."""
import argparse
import json
import os
from contextlib import closing
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import time
import uuid

from service.hub import Store
from service.network import RouteSetupError, ensure_private_route

SERVICE = "paceman-source.service"


def state_directory():
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "paceman"


def status_path():
    return Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "paceman/status.json"


def pause_path():
    return state_directory() / "sharing-paused"


def set_sharing(enabled):
    """A persistent user choice; upgrades and login must not silently undo it."""
    marker = pause_path()
    marker.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    was_paused = marker.exists()
    if enabled:
        marker.unlink(missing_ok=True)
    else:
        marker.write_text('{"paused":true}')
        marker.chmod(0o600)
    try:
        subprocess.run(["/usr/bin/systemctl", "--user", "enable" if enabled else "disable",
                        "--now", SERVICE], check=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        # Don't display a successful off state if systemd couldn't stop sharing.
        if was_paused:
            marker.write_text('{"paused":true}')
        else:
            marker.unlink(missing_ok=True)
        raise


def read_status(path=None, now=None):
    try:
        value = json.loads((path or status_path()).read_text())
        if value.get("schema") != 1:
            raise ValueError("Unknown status schema")
        for key in ("updatedAt", "lastPhoneFetchAt"):
            if not isinstance(value.get(key, 0), (float, int)):
                raise ValueError("Invalid status timestamp")
    except (OSError, ValueError, AttributeError):
        value = {"schema": 1, "running": False, "phoneRecent": False}
    if path is None:
        database = state_directory() / "hub.sqlite3"
        if database.is_file():
            with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
                value["clients"] = Store.client_list(db)
                value["pairedPhones"] = len(value["clients"])
        from omarchy.agents import configured_providers, detected_providers
        value["configuredProviders"] = configured_providers(state_directory())
        value["detectedProviders"] = detected_providers(state_directory())
        value["sharingEnabled"] = not pause_path().exists()
        value["computerName"] = socket.gethostname()
    now = time.time() if now is None else now
    value["running"] = bool(value.get("running")) and 0 <= now - value.get("updatedAt", 0) < 20
    value["phoneRecent"] = value["running"] and value.get("lastPhoneFetchAt", 0) > 0 and 0 <= now - value.get("lastPhoneFetchAt", 0) < 30
    return value


def remove_access(client_id):
    client_id = str(uuid.UUID(client_id))
    database = state_directory() / "hub.sqlite3"
    if not database.is_file():
        raise ValueError("Paceman's installed source database is missing.")
    Store(database).revoke(client_id)
    return read_status()


def pair_phone(open_image=False, json_output=False):
    if not read_status().get("running"):
        raise ValueError("Start Paceman before connecting a phone.")
    root = state_directory()
    if not (root / "hub.sqlite3").is_file():
        raise ValueError("Paceman's installed source database is missing.")
    if json_output and not Path("/usr/bin/qrencode").exists():
        raise ValueError("Install qrencode to show a pairing code in the panel.")
    origin = ensure_private_route(root)
    invitation = Store(root / "hub.sqlite3").invite(origin)
    path = root / "invitation.json"
    path.write_text(json.dumps(invitation, separators=(",", ":")))
    path.chmod(0o600)
    if Path("/usr/bin/qrencode").exists():
        image = root / "invitation.png"
        subprocess.run(["/usr/bin/qrencode", "-o", str(image), "-s", "8"],
                       input=path.read_text(), text=True, check=True, timeout=10)
        image.chmod(0o600)
        if open_image:
            subprocess.Popen(["/usr/bin/xdg-open", str(image)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        if json_output:
            print(json.dumps({"qrPath": str(image), "expiresAt": invitation["expiresAt"]}))
        else:
            print(f"Scan {image} in Paceman's Connect computer screen. Expires in five minutes.")
    else:
        print(f"Paste {path} into Paceman's Connect computer screen. Expires in five minutes.")
        if open_image:
            raise ValueError("Install qrencode to show a pairing QR. The private invitation JSON is ready.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Manage the Paceman desktop source")
    parser.add_argument("command", choices=("status", "start", "restart", "stop", "logs", "pair", "share-on", "share-off", "remove-access", "agents"))
    parser.add_argument("--client-id", help="Connection to remove (from pacemanctl status)")
    parser.add_argument("--open", action="store_true", help="Open the phone-pairing QR")
    parser.add_argument("--json", action="store_true", help="Return pairing image metadata for the panel")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--enable", choices=("codex", "claude"))
    selection.add_argument("--disable", choices=("codex", "claude"))
    args = parser.parse_args()
    if (args.enable or args.disable) and args.command != "agents":
        parser.error("--enable and --disable require the agents command")
    try:
        if args.command == "agents":
            from omarchy.agents import configure
            configure(state_directory(), Path(__file__).resolve().parents[1],
                      enable=args.enable, disable=args.disable)
            print(json.dumps(read_status()))
        elif args.command == "status":
            print(json.dumps(read_status(), indent=2))
        elif args.command == "remove-access":
            if not args.client_id:
                raise ValueError("Specify --client-id from pacemanctl status.")
            print(json.dumps(remove_access(args.client_id)))
        elif args.command == "pair":
            pair_phone(args.open, args.json)
        elif args.command in ("share-on", "share-off"):
            set_sharing(args.command == "share-on")
        elif args.command == "logs":
            subprocess.run(["/usr/bin/journalctl", "--user", "-u", SERVICE,
                            "-u", "paceman-push.service", "-n", "60", "--no-pager"], check=True)
        else:
            subprocess.run(["/usr/bin/systemctl", "--user", args.command, SERVICE], check=True, timeout=20)
    except RouteSetupError as error:
        print(f"Paceman route: {error}", file=sys.stderr)
        raise SystemExit(1)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Paceman: {error}", file=sys.stderr)
        raise SystemExit(1)
