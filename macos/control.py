"""Local macOS control boundary for the menu-bar client and setup agent."""
from __future__ import annotations

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import plistlib
import shlex
import socket
import sqlite3
import subprocess
import sys
import time
import uuid

from macos.agents import CLAUDE_PURPOSES, PROVIDERS, configured_providers, claude_config_dir, provider_config, hook_path
from service.network import ensure_private_route
from macos.codex_hook import EVENTS as CODEX_EVENTS, QUESTION_MATCHER
from service.hub import Store, endpoint
from macos.paths import installed_app

ROOT = Path.home() / "Library/Application Support/Paceman"
PLIST = Path.home() / "Library/LaunchAgents/ai.paceman.source.plist"
LABEL = "ai.paceman.source"


def missing_hooks(config_path: Path | None = None, script_path: Path | None = None, *, provider="codex") -> list[str]:
    events = CODEX_EVENTS if provider == "codex" else dict(CLAUDE_PURPOSES)
    config_path = config_path or hook_path(provider, root=ROOT)
    script_path = script_path or ROOT / f"lib/macos/{provider}_hook.py"
    if not script_path.is_file():
        return list(events)
    try:
        document = json.loads(config_path.read_text())
        if provider == "claude" and document.get("disableAllHooks") is True:
            return list(events)
        groups_by_event = document.get("hooks", {})
        if not isinstance(groups_by_event, dict):
            raise ValueError("Invalid hooks configuration")
    except (OSError, ValueError, AttributeError):
        return list(events)

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
    for event in events:
        groups = groups_by_event.get(event, [])
        if not isinstance(groups, list) or not any(
            isinstance(group, dict) and isinstance(group.get("hooks"), list)
            and (provider != "claude" or group.get("matcher") in (None, "", "*", ".*"))
            and (provider != "codex" or event != "PreToolUse" or group.get("matcher") == QUESTION_MATCHER)
            and any(installed(item) and not item.get("if") and not item.get("async") and not item.get("asyncRewake") for item in group["hooks"])
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
    providers = configured_providers(ROOT)
    value["configuredProviders"] = providers
    value["missingHooksByProvider"] = {p: missing_hooks(provider=p) for p in providers}
    value["missingHooks"] = [event for missing in value["missingHooksByProvider"].values() for event in missing]
    try:
        arguments = plistlib.loads(PLIST.read_bytes()).get("ProgramArguments", [])
        if len(arguments) >= 2 and isinstance(arguments[1], str):
            value["hookCommands"] = {p: shlex.quote(arguments[1]) + " -B " +
                                    shlex.quote(str(ROOT / f"lib/macos/{p}_hook.py")) for p in providers}
            value["hookCommand"] = value["hookCommands"].get("codex")
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


def pairing():
    current = status()
    if not current["sharingEnabled"]:
        raise ValueError("Turn on Sharing before connecting your iPhone")
    if not current["running"]:
        raise ValueError("Start Paceman before connecting a phone")
    origin = ensure_private_route(ROOT)
    invitation = Store(ROOT / "data/hub.sqlite3").invite(endpoint(origin))
    print(json.dumps(invitation, separators=(",", ":")))


def remove_access(client_id):
    Store(ROOT / "data/hub.sqlite3").revoke(str(uuid.UUID(client_id)))


def configure_agents(providers):
    """Prepare reviewable hooks, preserve unrelated settings, roll back on failure."""
    import tempfile
    from macos import install as installer
    from macos.uninstall import cleaned_hooks
    providers = list(dict.fromkeys(providers))
    if not providers or any(p not in PROVIDERS for p in providers):
        raise ValueError("Choose at least one supported agent")
    try:
        arguments = plistlib.loads(PLIST.read_bytes()).get("ProgramArguments", [])
        if len(arguments) >= 2 and Path(arguments[1]).is_file():
            installer.PYTHON = arguments[1]
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        pass
    targets = []
    with tempfile.TemporaryDirectory(prefix=".agents-", dir=ROOT) as temporary:
        staging = Path(temporary)
        for provider in dict.fromkeys([*configured_providers(ROOT), *providers]):
            target = hook_path(provider, root=ROOT)
            original = target.read_bytes() if target.exists() else None
            staged = staging / (provider + '.json')
            if original is not None:
                staged.write_bytes(original)
            if provider in providers:
                installer.install_hooks(staged, provider=provider)
            else:
                cleaned = cleaned_hooks(staged, provider=provider)
                if cleaned is None:
                    continue
                staged.write_text(json.dumps(cleaned, indent=2) + "\n")
            targets.append((target, original, staged.read_bytes()))
        target = ROOT / 'agents.json'
        targets.append((target, target.read_bytes() if target.exists() else None,
                        (json.dumps(provider_config(providers, ROOT)) + "\n").encode()))
        replaced = []
        def write(target, data):
            if data is None:
                target.unlink(missing_ok=True)
                return
            target.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(prefix='.paceman-agents-', dir=target.parent)
            try:
                with os.fdopen(descriptor, 'wb') as output:
                    output.write(data)
                Path(temporary).replace(target)
            finally:
                Path(temporary).unlink(missing_ok=True)
        try:
            for target, original, data in targets:
                write(target, data)
                replaced.append((target, original))
            if not (ROOT / 'sharing-paused').exists():
                launch('kickstart', '-k', service_target())
        except Exception:
            for target, original in reversed(replaced):
                write(target, original)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "support", "pair", "share-on", "share-off", "restart", "remove-access", "uninstall", "allow-claude-usage", "agents"))
    parser.add_argument("--client-id")
    parser.add_argument("--providers", nargs="+", choices=PROVIDERS)
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
        elif args.command == "agents":
            if not args.providers:
                raise ValueError("Choose at least one agent with --providers")
            configure_agents(args.providers)
            print("Agent settings updated. Review the selected agents’ Paceman hook commands, then start a fresh local task.")
        elif args.command == "allow-claude-usage":
            from service.claude_limits import read_claude_allowances
            directory = claude_config_dir(ROOT)
            # The default Keychain is scoped to the default Claude profile.
            os.environ["CLAUDE_CONFIG_DIR"] = str(directory)
            _, result = read_claude_allowances(allow_prompt=True)
            print(json.dumps({"claudeUsageStatus": result}))
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
