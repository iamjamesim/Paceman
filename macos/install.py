"""Agent-led per-user Mac install; preserves pairing and sharing preference."""
from __future__ import annotations

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile

from macos.codex_hook import QUESTION_MATCHER
from macos.agents import CLAUDE_PURPOSES, provider_config, PROVIDERS, configured_providers, setup_providers, hook_path, installed_hook_command
from macos.paths import installed_app
from service.hub import endpoint
from service.network import RouteSetupError, ensure_private_route
from service.push import DEFAULT_RELAY_URL

REPO = Path(__file__).resolve().parent.parent
ROOT = Path.home() / "Library/Application Support/Paceman"
APP = installed_app()
BUNDLE_ID = "ai.paceman.macos"
PLIST = Path.home() / "Library/LaunchAgents/ai.paceman.source.plist"
LABEL = "ai.paceman.source"
PUSH_LABEL = "ai.paceman.push"
PUSH_PLIST = Path.home() / "Library/LaunchAgents/ai.paceman.push.plist"
LOGIN_ATTENTION = ROOT / "login-setup-incomplete"


def signing_identity() -> str | None:
    """Use an installed Apple identity from the team that signs the iPhone app."""
    project = (REPO / "ios/AgentCompanion.xcodeproj/project.pbxproj").read_text()
    teams = set(re.findall(r'DEVELOPMENT_TEAM"?\s*=\s*"?([A-Z0-9]{10})', project))
    if len(teams) != 1:
        return None
    identities = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                                capture_output=True, text=True, check=False)
    available = set(re.findall(r"\b([A-F0-9]{40})\b", identities.stdout))
    if not available:
        return None
    certificates = subprocess.run(["/usr/bin/security", "find-certificate", "-a", "-p"],
                                  capture_output=True, check=False)
    matches = []
    for certificate in re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                                  certificates.stdout, re.S):
        details = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-fingerprint",
                                  "-sha1"], input=certificate, capture_output=True, check=False)
        output = details.stdout.decode(errors="replace")
        team = re.search(r"\bOU\s*=\s*([A-Z0-9]{10})", output)
        fingerprint = re.search(r"Fingerprint=([A-Fa-f0-9:]+)", output)
        if team and team.group(1) in teams and fingerprint:
            identity = fingerprint.group(1).replace(":", "").upper()
            if identity in available:
                matches.append(("Developer ID Application" in output, identity))
    return sorted(matches, reverse=True)[0][1] if matches else None


def runtime_python() -> str:
    """Use a PATH entry outside this checkout so removing a venv won't break login."""
    candidates = [Path(folder) / "python3" for folder in os.environ.get("PATH", "").split(os.pathsep) if folder]
    candidates += [Path("/opt/homebrew/bin/python3"), Path("/usr/local/bin/python3"), Path(sys.executable)]
    seen = set()
    for path in candidates:
        path = path.absolute()
        if path in seen or path.is_relative_to(REPO) or not path.is_file():
            continue
        seen.add(path)
        try:
            result = subprocess.run([str(path), "-c", "import sys; print(*sys.version_info[:2])"],
                                    check=True, capture_output=True, text=True, timeout=5)
            if tuple(map(int, result.stdout.split())) >= (3, 11):
                return str(path)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
    raise ValueError("Install Python 3.11 or newer outside this checkout")


PYTHON = runtime_python()
HOOK_PURPOSES = (
    ("SessionStart", "show a new Codex task as idle"),
    ("UserPromptSubmit", "show the task as working when a prompt is sent"),
    ("PermissionRequest", "show input needed if approval remains pending for five seconds"),
    ("PreToolUse", "show input needed if a blocking or async question remains pending for five seconds"),
    ("PostToolUse", "return the task to working after a tool finishes"),
    ("Stop", "show the task as finished when its turn ends"),
    ("Interrupt", "show the task as idle when its turn is interrupted"),
    ("SessionEnd", "remove the task when its session ends"),
)
HOOK_EVENTS = tuple(event for event, _ in HOOK_PURPOSES)


def install_hooks(path: Path | None = None, *, provider="codex"):
    if provider not in PROVIDERS:
        raise ValueError("Unsupported agent provider")
    path = path or hook_path(provider, root=ROOT)
    path.parent.mkdir(parents=True, exist_ok=True)
    document = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(document, dict):
        raise ValueError("Existing ~/.codex/hooks.json is not a JSON object")
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing hooks configuration is not an object")
    script = str(ROOT / f"lib/macos/{provider}_hook.py")
    command = shlex.quote(PYTHON) + " -B " + shlex.quote(script)
    changed = []
    for event in (HOOK_EVENTS if provider == "codex" else tuple(e for e, _ in CLAUDE_PURPOSES)):
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise ValueError(f"Existing {event} hooks are not a list")
        installed = False
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            for item in group["hooks"]:
                if not isinstance(item, dict):
                    continue
                try:
                    arguments = shlex.split(item.get("command", ""))
                except (TypeError, ValueError):
                    continue
                if len(arguments) in (2, 3) and arguments[-1] == script:
                    installed = True
                    if provider == "codex" and event == "PreToolUse" and group.get("matcher") != QUESTION_MATCHER:
                        # Matcher belongs to the group. Keep unrelated handlers
                        # in a shared group on their original match pattern.
                        if len(group["hooks"]) == 1:
                            group["matcher"] = QUESTION_MATCHER
                        else:
                            group["hooks"].remove(item)
                            groups.append({"matcher": QUESTION_MATCHER, "hooks": [item]})
                        changed.append(event)
                    if provider == "claude" and group.get("matcher") not in (None, "", "*", ".*"):
                        if len(group["hooks"]) == 1:
                            group.pop("matcher", None)
                        else:
                            group["hooks"].remove(item)
                            groups.append({"hooks": [item]})
                        if event not in changed:
                            changed.append(event)
                    # Paceman is observational on every selected event.
                    for field in ("if", "async", "asyncRewake"):
                        if field in item:
                            item.pop(field)
                            if event not in changed:
                                changed.append(event)
                    # Codex trust is bound to the definition. Keep a usable
                    # existing interpreter and spelling across runtime updates.
                    updates = {}
                    if item.get("type") != "command":
                        updates["type"] = "command"
                    if (not Path(arguments[0]).is_absolute() or not Path(arguments[0]).is_file()
                            or not os.access(arguments[0], os.X_OK)
                            or len(arguments) == 3 and arguments[1] != "-B"):
                        updates["command"] = command
                    if "timeout" in item and (type(item["timeout"]) is not int or item["timeout"] <= 0):
                        updates["timeout"] = 3
                    if updates:
                        item.update(updates)
                        if event not in changed:
                            changed.append(event)
                    break
            if installed:
                break
        if not installed:
            group = {"hooks": [{"type": "command", "command": command, "timeout": 3}]}
            if provider == "codex" and event == "PreToolUse":
                group["matcher"] = QUESTION_MATCHER
            groups.append(group)
            changed.append(event)
    if not changed:
        return changed
    descriptor, name = tempfile.mkstemp(prefix=".paceman-hooks-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(json.dumps(document, indent=2) + "\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return changed


def build_app(destination: Path | None = None, *, version: str = "0.1",
              build_number: str = "1", minimum_macos: str = "15.0",
              sign: bool = True):
    destination = destination or APP
    executable = destination / "Contents/MacOS/Paceman"
    executable.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-target",
                    f"arm64-apple-macosx{minimum_macos}", str(REPO / "macos/PacemanMac.swift"),
                    str(REPO / "ios/Shared/PacemanMark.swift"),
                    "-o", str(executable)], check=True, cwd=REPO)
    subprocess.run(["/usr/bin/xcrun", "clang", "-O2", "-Wall", "-Wextra", "-target",
                    f"arm64-apple-macos{minimum_macos}", str(REPO / "macos/PacemanBackground.c"),
                    "-o", str(executable.parent / "PacemanBackground")], check=True, cwd=REPO)
    resources = destination / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    iconset = resources / "Paceman.iconset"
    iconset.mkdir()
    artwork = REPO / "ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            size = points * scale
            suffix = "@2x" if scale == 2 else ""
            subprocess.run(["/usr/bin/sips", "-z", str(size), str(size), str(artwork),
                            "--out", str(iconset / f"icon_{points}x{points}{suffix}.png")],
                           check=True, capture_output=True)
    subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o",
                    str(resources / "Paceman.icns")], check=True)
    shutil.rmtree(iconset)
    info = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleName": "Paceman",
            "CFBundleDisplayName": "Paceman", "CFBundleExecutable": "Paceman",
            "CFBundleIconFile": "Paceman.icns",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
            "CFBundleVersion": build_number, "LSMinimumSystemVersion": minimum_macos,
            "LSUIElement": True}
    (destination / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    if not sign:
        return
    identity = signing_identity() or "-"
    helper = executable.parent / "PacemanBackground"
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, str(helper)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, str(destination)], check=True)
    print("Paceman signing:", "Apple team identity" if identity != "-" else "ad hoc (unidentified developer)")


def install(*, relay_url: str | None = DEFAULT_RELAY_URL, replace_push_config: bool = False,
            prebuilt_app: Path | None = None, agents: list[str] | None = None):
    global PYTHON
    if sys.version_info < (3, 11):
        raise ValueError("Install Python 3.11 or newer and run this installer with it")
    if prebuilt_app is not None:
        prebuilt_app = prebuilt_app.expanduser().resolve(strict=True)
        info = prebuilt_app / "Contents/Info.plist"
        if (not info.is_file() or
                plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != BUNDLE_ID or
                REPO.resolve() != (prebuilt_app / "Contents/Resources/lib").resolve()):
            raise ValueError("The prebuilt app and its installer do not match")
        if not (prebuilt_app / "Contents/Resources/python/bin/python3").is_file():
            raise ValueError("The prebuilt app has no bundled Python runtime")
        PYTHON = str(APP / "Contents/Resources/python/bin/python3")
    if relay_url is not None:
        relay_url = endpoint(relay_url)
    if agents is None:
        agents = setup_providers(ROOT)
    if any(p not in PROVIDERS for p in agents):
        raise ValueError("Unsupported agent selection")
    agents = list(dict.fromkeys(agents))
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    ROOT.chmod(0o700)
    (ROOT / "data").mkdir(exist_ok=True, mode=0o700)
    (ROOT / "data").chmod(0o700)
    if APP.exists():
        info = APP / "Contents/Info.plist"
        if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != BUNDLE_ID:
            raise ValueError(f"Refusing to replace another app at {APP}")
    staging = Path(tempfile.mkdtemp(prefix=".install-", dir=ROOT))
    staged_app = staging / "Paceman.app"
    try:
        if prebuilt_app is None:
            build_app(staged_app)
        elif prebuilt_app != APP.resolve():
            shutil.copytree(prebuilt_app, staged_app, symlinks=True)
        notifications_ready = _finish_install(staged_app, relay_url=relay_url,
                                              replace_push_config=replace_push_config,
                                              open_menu=prebuilt_app is None,
                                              stop_installed_menu=(prebuilt_app is None or
                                                                   prebuilt_app != APP.resolve()),
                                              replace_app=prebuilt_app != APP.resolve(), agents=agents)
    finally:
        if not (staging / "ROLLBACK_INCOMPLETE").exists():
            shutil.rmtree(staging, ignore_errors=True)
    return notifications_ready


def _finish_install(staged_app: Path, *, relay_url: str | None = None,
                    replace_push_config: bool = False, open_menu: bool = True,
                    stop_installed_menu: bool = True, replace_app: bool = True,
                    agents: list[str] | None = None):
    if agents is None:
        agents = setup_providers(ROOT)
    try:
        previous_status = json.loads((ROOT / "status.json").read_text())
        had_activity = previous_status.get("mode") == "macos" and float(previous_status.get("lastAgentEventAt", 0)) > 0
    except (OSError, ValueError, TypeError, AttributeError):
        had_activity = False
    label = f"gui/{os.getuid()}/{LABEL}"
    push_label = f"gui/{os.getuid()}/{PUSH_LABEL}"
    if PLIST.is_file() and plistlib.loads(PLIST.read_bytes()).get("Label") != LABEL:
        raise ValueError(f"Refusing to replace unrelated background item at {PLIST}")
    if PUSH_PLIST.is_file():
        if plistlib.loads(PUSH_PLIST.read_bytes()).get("Label") != PUSH_LABEL:
            raise ValueError(f"Refusing to replace unrelated background item at {PUSH_PLIST}")

    # Prepare every replacement before stopping the installed service.
    staging = staged_app.parent
    staged_lib = staging / "lib"
    staged_lib.mkdir()
    for folder in ("service", "macos"):
        shutil.copytree(REPO / folder, staged_lib / folder,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    staged_wrapper = staging / "pacemanctl"
    staged_wrapper.write_text((REPO / "macos/launch_control.py").read_text().replace(
        "#!/usr/bin/python3 -I", f"#!{PYTHON} -IB", 1))
    staged_wrapper.chmod(0o700)

    lib = ROOT / "lib"
    bin_dir = ROOT / "bin"
    wrapper = bin_dir / "pacemanctl"
    staged_plist = staging / "source.plist"
    bundled_python = str(APP / "Contents/Resources/python/bin/python3")
    push_python = bundled_python if PYTHON == bundled_python else str(ROOT / "push-venv/bin/python3")
    existing_push_config = ROOT / "private/apns.json"
    if push_python == bundled_python and existing_push_config.is_file():
        try:
            if "relayURL" not in json.loads(existing_push_config.read_text()):
                push_python = str(ROOT / "push-venv/bin/python3")
        except (OSError, ValueError, TypeError):
            pass
    document = {"Label": LABEL, "AssociatedBundleIdentifiers": [BUNDLE_ID],
                "ProgramArguments": [str(APP / "Contents/MacOS/PacemanBackground"),
                                     PYTHON, str(ROOT), push_python],
                "WorkingDirectory": str(lib), "RunAtLoad": True, "KeepAlive": True,
                "StandardOutPath": str(ROOT / "background.log"),
                "StandardErrorPath": str(ROOT / "background-error.log")}
    staged_plist.write_bytes(plistlib.dumps(document))
    staged_plist.chmod(0o600)

    staged_hooks_by_provider = {}
    changed_by_provider = {}
    for provider in dict.fromkeys([*configured_providers(ROOT), *agents]):
        hooks_path = hook_path(provider, root=ROOT)
        staged_hooks = staging / ("hooks.json" if provider == "codex" else "claude-settings.json")
        if hooks_path.exists():
            shutil.copy2(hooks_path, staged_hooks)
        if provider in agents:
            changed_by_provider[provider] = install_hooks(staged_hooks, provider=provider)
        else:
            from macos.uninstall import cleaned_hooks
            cleaned = cleaned_hooks(staged_hooks, provider=provider)
            changed_by_provider[provider] = ["removed"] if cleaned is not None else []
            if cleaned is not None:
                staged_hooks.write_text(json.dumps(cleaned, indent=2) + "\n")
        staged_hooks_by_provider[provider] = (staged_hooks, hooks_path)
        if changed_by_provider[provider]:
            hooks_path.parent.mkdir(parents=True, exist_ok=True)
    changed_hooks = changed_by_provider.get("codex", [])
    staged_agents = staging / "agents.json"
    staged_agents.write_text(json.dumps(provider_config(agents, ROOT)) + "\n")
    lib.mkdir(exist_ok=True)
    bin_dir.mkdir(exist_ok=True)
    APP.parent.mkdir(parents=True, exist_ok=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)

    backups = staging / "backup"
    backups.mkdir()
    replaced = []

    def replace(staged: Path | None, target: Path, name: str):
        backup = backups / name if target.exists() or target.is_symlink() else None
        if backup is not None:
            target.replace(backup)
        replaced.append((target, backup))
        if staged is not None:
            staged.replace(target)

    def remove(path: Path):
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)

    source_was_loaded = False
    push_was_loaded = False
    try:
        if PUSH_PLIST.is_file():
            push_was_loaded = subprocess.run(["/bin/launchctl", "print", push_label],
                                             stdout=subprocess.DEVNULL,
                                             stderr=subprocess.DEVNULL).returncode == 0
            if push_was_loaded:
                subprocess.run(["/bin/launchctl", "bootout", push_label], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        source_was_loaded = subprocess.run(["/bin/launchctl", "print", label],
                                           stdout=subprocess.DEVNULL,
                                           stderr=subprocess.DEVNULL).returncode == 0
        if source_was_loaded:
            subprocess.run(["/bin/launchctl", "bootout", label], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for folder in ("service", "macos"):
            replace(staged_lib / folder, lib / folder, folder)
        if (lib / "desktop").exists() or (lib / "desktop").is_symlink():
            replace(None, lib / "desktop", "desktop")
        replace(staged_wrapper, wrapper, "pacemanctl")
        if replace_app:
            replace(staged_app, APP, "Paceman.app")
        replace(staged_plist, PLIST, "source.plist")
        # The source reads its selected providers during startup. Commit this
        # before bootstrap so a fresh Claude install cannot start Codex-only.
        replace(staged_agents, ROOT / "agents.json", "agents.json")
        if not (ROOT / "sharing-paused").exists():
            subprocess.run(["/bin/launchctl", "enable", label], check=True)
            subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(PLIST)], check=True)
        if PUSH_PLIST.is_file():
            replace(None, PUSH_PLIST, "push.plist")
        for provider, (staged_hooks, hooks_path) in staged_hooks_by_provider.items():
            if changed_by_provider[provider]:
                replace(staged_hooks, hooks_path, "hooks.json" if provider == "codex" else "claude-settings.json")
    except Exception as error:
        rollback_errors = []
        try:
            subprocess.run(["/bin/launchctl", "bootout", label], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except OSError as rollback_error:
            rollback_errors.append(str(rollback_error))
        for target, backup in reversed(replaced):
            try:
                remove(target)
                if backup is not None:
                    backup.replace(target)
            except OSError as rollback_error:
                rollback_errors.append(str(rollback_error))
        if source_was_loaded and PLIST.is_file():
            try:
                restored = subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(PLIST)],
                                          capture_output=True, text=True)
                if restored.returncode:
                    rollback_errors.append(f"could not restart previous Paceman source: {restored.stderr.strip()}")
            except OSError as rollback_error:
                rollback_errors.append(f"could not restart previous Paceman source: {rollback_error}")
        if push_was_loaded and PUSH_PLIST.is_file():
            try:
                restored = subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(PUSH_PLIST)],
                                          capture_output=True, text=True)
                if restored.returncode:
                    rollback_errors.append(f"could not restart previous push worker: {restored.stderr.strip()}")
            except OSError as rollback_error:
                rollback_errors.append(f"could not restart previous push worker: {rollback_error}")
        if rollback_errors:
            (staging / "ROLLBACK_INCOMPLETE").write_text("Previous installation could not be fully restored.\n")
            raise OSError(f"Install failed ({error}); rollback incomplete: {'; '.join(rollback_errors)}. "
                          f"Recovery files were kept at {staging}") from error
        raise

    notifications_ready = True
    relay_configured_now = False
    push_config = ROOT / "private/apns.json"
    if relay_url is not None and (replace_push_config or not push_config.is_file()):
        try:
            # A paused source may never have started; create its persistent ID
            # before configuring push so the first pairing includes the relay.
            from service.hub import Store
            from macos import install_push
            Store(ROOT / "data/hub.sqlite3")
            install_push.install(relay_url=relay_url)
            relay_configured_now = True
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            notifications_ready = False
            print(f"Notification setup is incomplete: {error}", file=sys.stderr)
            print(f"The Mac source is installed. Retry with {shlex.quote(PYTHON)} -m macos.install_push "
                  f"--relay-url {shlex.quote(relay_url)}", file=sys.stderr)
    elif push_config.is_file():
        try:
            from service.hub import Store
            from service.push import Config, RelayConfig
            raw = json.loads(push_config.read_text())
            if isinstance(raw, dict) and "relayURL" in raw:
                relay = RelayConfig.load(raw)
                if relay.source_id != Store(ROOT / "data/hub.sqlite3").metadata("source_id"):
                    raise ValueError("Relay source ID does not match this installation")
            else:
                Config.load(push_config)
            worker_arguments = plistlib.loads(PLIST.read_bytes()).get("ProgramArguments", [])
            worker_python = (worker_arguments[3] if len(worker_arguments) >= 4
                             else str(ROOT / "push-venv/bin/python3"))
            if not Path(worker_python).is_file():
                raise ValueError("Push worker environment is missing")
            print("Existing iPhone notification configuration preserved.")
        except (OSError, ValueError, TypeError) as error:
            notifications_ready = False
            print(f"Existing notification setup needs repair: {error}", file=sys.stderr)
    else:
        print("Notification setup skipped as requested. Configure a relay before pairing a phone.")

    if stop_installed_menu:
        executable = str(APP / "Contents/MacOS/Paceman")
        try:
            running = subprocess.run(["/usr/bin/pgrep", "-U", str(os.getuid()),
                                      "-f", "-x", executable], capture_output=True,
                                     text=True, timeout=5)
            if running.returncode == 0:
                for value in running.stdout.splitlines():
                    os.kill(int(value), signal.SIGTERM)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    opened = False
    if open_menu:
        try:
            opened = subprocess.run(["/usr/bin/open", "-n", "-a", str(APP)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        except OSError:
            pass
    login_marker = ROOT / "menu-login-configured"
    if not login_marker.exists() or LOGIN_ATTENTION.exists():
        try:
            login = subprocess.run([str(APP / "Contents/MacOS/Paceman"), "--register-login"],
                                   capture_output=True, text=True, timeout=20)
            if login.returncode == 0:
                login_marker.write_text("registered\n")
                login_marker.chmod(0o600)
                LOGIN_ATTENTION.unlink(missing_ok=True)
                print("Paceman menu app will open at login; change this in Manage Paceman.")
            else:
                LOGIN_ATTENTION.write_text("Retry Paceman Open at Login setup.\n")
                LOGIN_ATTENTION.chmod(0o600)
                print("Open at Login needs attention:", login.stderr.strip() or "registration failed")
        except (OSError, subprocess.SubprocessError) as error:
            LOGIN_ATTENTION.write_text("Retry Paceman Open at Login setup.\n")
            LOGIN_ATTENTION.chmod(0o600)
            print("Open at Login needs attention:", error)
    print(f"Installed {APP}")
    print("Mac background activity: one Paceman item for the local source and iPhone notifications when configured.")
    print("The Paceman menu-bar app is open." if opened else f"Open the menu app from {APP}.")
    print("Manage Paceman controls whether the menu app opens at login.")
    print("Its Sharing switch pauses the background item;")
    print("Manage Paceman in the panel explains removal and offers Uninstall Paceman.")
    print(f"Control: {wrapper}")
    if "codex" in agents and not changed_hooks and had_activity:
        print("Codex hooks are installed and have delivered activity before.")
        print("If a new local Codex task does not appear, review Paceman in Codex")
        print("Settings > Hooks (CLI: /hooks) and check pacemanctl status.")
    elif "codex" in agents:
        print("NEXT: Guide the user through Paceman hook review before testing activity.")
        print_hook_review_steps(wrapper)
    if "claude" in agents:
        print_claude_review_steps(wrapper)
    if notifications_ready and push_config.is_file():
        print("The Mac background item also runs the configured iPhone notification worker.")
    paired = 0
    database_path = ROOT / "data/hub.sqlite3"
    if database_path.is_file():
        try:
            with closing(sqlite3.connect(f"file:{database_path}?mode=ro", uri=True)) as database:
                paired = database.execute("SELECT COUNT(*) FROM clients").fetchone()[0]
        except sqlite3.Error:
            # The source may not have initialized the database if sharing is off.
            pass
    route_ready = False
    if not (ROOT / "sharing-paused").exists():
        try:
            ensure_private_route(ROOT)
            route_ready = True
            print("Private phone connection ready through Tailscale.")
        except RouteSetupError as error:
            print(f"Phone connection setup is incomplete: {error}", file=sys.stderr)
            print("Complete the Tailscale step, then use the menu-bar pairing button to retry.", file=sys.stderr)
    if paired:
        print(f"Phone pairing preserved: {paired} connected installation{'s' if paired != 1 else ''}.")
        if relay_configured_now:
            print("Re-pair an existing phone if it was paired before relay setup.")
    else:
        if route_ready:
            print("NEXT: Click Paceman's QR button and scan it in the iPhone app's Connect computer flow.")
    (ROOT / "installed-app").write_text(str(APP) + "\n")
    installed_build = ROOT / "installed-build"
    if PYTHON == str(APP / "Contents/Resources/python/bin/python3"):
        info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        build = str(info["CFBundleVersion"])
        descriptor, name = tempfile.mkstemp(prefix=".paceman-build-", dir=ROOT)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "w") as output:
                output.write(build + "\n")
            temporary.replace(installed_build)
        finally:
            temporary.unlink(missing_ok=True)
    else:
        installed_build.unlink(missing_ok=True)
    notification_marker = ROOT / "notification-setup-incomplete"
    if notifications_ready:
        notification_marker.unlink(missing_ok=True)
    else:
        notification_marker.write_text("Retry Paceman notification setup.\n")
        notification_marker.chmod(0o600)
    # Route recovery belongs to phone pairing, which displays the prerequisite and
    # retries it. Exit 2 is reserved for notification setup and its repair marker.
    return notifications_ready


def print_claude_review_steps(wrapper: Path):
    print("NEXT: Review Paceman's Claude hooks before checking activity.")
    print("  Claude CLI: /hooks. VS Code/desktop Code: inspect the local user settings.")
    print(f"  Claude settings: {hook_path('claude', root=ROOT)}")
    print("  Check the user-settings entries and this exact command:")
    print("     " + (installed_hook_command("claude", ROOT) or f"{shlex.quote(PYTHON)} -B {shlex.quote(str(ROOT / 'lib/macos/claude_hook.py'))}"))
    for event, purpose in CLAUDE_PURPOSES:
        print(f"     {event}: {purpose}")
    print("  Only event names, opaque IDs and an optional short project label leave the hook.")
    print("  No prompts, replies, transcript contents or tool arguments are sent.")
    print("  Requires Claude Code 2.1.196 or later; restart existing sessions after setup.")
    print("  Send a prompt in a fresh local Claude session and verify lastAgentEventByProvider.claude.")
    print("  Claude Code activity is supported; usage limits are not supported.")
    print(f"  Status: {shlex.quote(str(wrapper))} status")


def print_hook_review_steps(wrapper: Path):
    print("  Codex app: Settings > Hooks > User config (All projects).")
    print("  Codex CLI: enter /hooks, or choose Review hooks at startup.")
    print("  Codex calls each row 'Hook 1'. Identify Paceman by expanding the row")
    print("  and checking its source (User config, ~/.codex/hooks.json) and command:")
    print("     " + (installed_hook_command("codex", ROOT) or f"{shlex.quote(PYTHON)} -B {shlex.quote(str(ROOT / 'lib/macos/codex_hook.py'))}"))
    print("  Review these eight event rows with the user:")
    for event, purpose in HOOK_PURPOSES:
        print(f"     {event}: {purpose}")
    print("  The script sends event names, opaque session/turn IDs, and an optional")
    print("  short project label to the private local Paceman socket; no prompts,")
    print("  replies, transcripts, tool arguments, or project paths.")
    print("  The user decides whether to trust each Paceman row individually.")
    print("  Do not choose Trust all or bypass review.")
    print("  Stay with the user, then send a short prompt in a fresh saved local task")
    print("  in their Codex app or interactive CLI; do not use codex exec --ephemeral.")
    print("  Verify lastAgentEventAt advances in:")
    print(f'     "{wrapper}" status')
    print("  Wait for a successful reply and confirm Paceman shows the task as Finished.")
    print("  A start event alone is insufficient. If the check fails, inspect any leftover Working row.")
    print(f"  Until review and this check succeed, setup is partial. Full steps: {REPO / 'macos/README.md'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--relay-url", help="Use a self-hosted relay instead of the Paceman relay")
    selection.add_argument("--no-push-setup", action="store_true",
                           help="Skip automatic relay setup for a developer-managed sender")
    parser.add_argument("--prebuilt-app", type=Path,
                        help="Install the signed app bundle without Xcode or an external Python")
    parser.add_argument("--agents", nargs="*", choices=PROVIDERS, help="Agents to monitor; updates preserve the existing selection")
    arguments = parser.parse_args()
    try:
        ready = install(relay_url=None if arguments.no_push_setup else
                        arguments.relay_url or DEFAULT_RELAY_URL,
                        replace_push_config=arguments.relay_url is not None,
                        prebuilt_app=arguments.prebuilt_app, agents=arguments.agents)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Paceman install failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    if not ready:
        raise SystemExit(2)
