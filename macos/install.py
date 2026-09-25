"""Agent-led per-user Mac install; preserves pairing and sharing preference."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
ROOT = Path.home() / "Library/Application Support/Paceman"
APP = Path.home() / "Applications/Paceman.app"
PLIST = Path.home() / "Library/LaunchAgents/dev.paceman.source.plist"
LABEL = "dev.paceman.source"
PUSH_LABEL = "dev.paceman.push"
PUSH_PLIST = Path.home() / "Library/LaunchAgents/dev.paceman.push.plist"


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
    ("PostToolUse", "return the task to working after a tool finishes"),
    ("Stop", "show the task as finished when its turn ends"),
    ("Interrupt", "show the task as idle when its turn is interrupted"),
    ("SessionEnd", "remove the task when its session ends"),
)
HOOK_EVENTS = tuple(event for event, _ in HOOK_PURPOSES)


def install_hooks(path: Path | None = None):
    path = path or Path.home() / ".codex/hooks.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    document = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(document, dict):
        raise ValueError("Existing ~/.codex/hooks.json is not a JSON object")
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing hooks configuration is not an object")
    script = str(ROOT / "lib/macos/codex_hook.py")
    command = shlex.quote(PYTHON) + " " + shlex.quote(script)
    changed = []
    for event in HOOK_EVENTS:
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
                if len(arguments) == 2 and arguments[1] == script:
                    installed = True
                    if item.get("type") != "command" or item.get("command") != command or item.get("timeout") != 3:
                        item.update(type="command", command=command, timeout=3)
                        changed.append(event)
                    break
            if installed:
                break
        if not installed:
            groups.append({"hooks": [{"type": "command", "command": command, "timeout": 3}]})
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


def build_app(destination: Path | None = None):
    destination = destination or APP
    executable = destination / "Contents/MacOS/Paceman"
    executable.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-target",
                    "arm64-apple-macosx13.0", str(REPO / "macos/PacemanMac.swift"),
                    str(REPO / "ios/Shared/PacemanMark.swift"),
                    "-o", str(executable)], check=True, cwd=REPO)
    subprocess.run(["/usr/bin/xcrun", "clang", "-O2", "-Wall", "-Wextra", "-target",
                    "arm64-apple-macos13.0", str(REPO / "macos/PacemanBackground.c"),
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
    info = {"CFBundleIdentifier": "dev.paceman.macos", "CFBundleName": "Paceman",
            "CFBundleDisplayName": "Paceman", "CFBundleExecutable": "Paceman",
            "CFBundleIconFile": "Paceman.icns",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1",
            "CFBundleVersion": "1", "LSMinimumSystemVersion": "13.0", "LSUIElement": True}
    (destination / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    identity = signing_identity() or "-"
    helper = executable.parent / "PacemanBackground"
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, str(helper)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, str(destination)], check=True)
    print("Paceman signing:", "Apple team identity" if identity != "-" else "ad hoc (unidentified developer)")


def install():
    if sys.version_info < (3, 11):
        raise ValueError("Install Python 3.11 or newer and run this installer with it")
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    ROOT.chmod(0o700)
    (ROOT / "data").mkdir(exist_ok=True, mode=0o700)
    (ROOT / "data").chmod(0o700)
    if APP.exists():
        info = APP / "Contents/Info.plist"
        if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != "dev.paceman.macos":
            raise ValueError(f"Refusing to replace another app at {APP}")
    staging = Path(tempfile.mkdtemp(prefix=".install-", dir=ROOT))
    staged_app = staging / "Paceman.app"
    try:
        build_app(staged_app)
        _finish_install(staged_app)
    finally:
        if not (staging / "ROLLBACK_INCOMPLETE").exists():
            shutil.rmtree(staging, ignore_errors=True)


def _finish_install(staged_app: Path):
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
    for folder in ("service", "desktop", "macos"):
        shutil.copytree(REPO / folder, staged_lib / folder,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    staged_wrapper = staging / "pacemanctl"
    staged_wrapper.write_text((REPO / "macos/launch_control.py").read_text().replace(
        "#!/usr/bin/python3 -I", f"#!{PYTHON} -I", 1))
    staged_wrapper.chmod(0o700)

    lib = ROOT / "lib"
    bin_dir = ROOT / "bin"
    wrapper = bin_dir / "pacemanctl"
    staged_plist = staging / "source.plist"
    document = {"Label": LABEL, "AssociatedBundleIdentifiers": ["dev.paceman.macos"],
                "ProgramArguments": [str(APP / "Contents/MacOS/PacemanBackground"), PYTHON, str(ROOT)],
                "WorkingDirectory": str(lib), "RunAtLoad": True, "KeepAlive": True,
                "StandardOutPath": str(ROOT / "background.log"),
                "StandardErrorPath": str(ROOT / "background-error.log")}
    staged_plist.write_bytes(plistlib.dumps(document))
    staged_plist.chmod(0o600)

    hooks_path = Path.home() / ".codex/hooks.json"
    staged_hooks = staging / "hooks.json"
    if hooks_path.exists():
        shutil.copy2(hooks_path, staged_hooks)
    changed_hooks = install_hooks(staged_hooks)

    lib.mkdir(exist_ok=True)
    bin_dir.mkdir(exist_ok=True)
    APP.parent.mkdir(parents=True, exist_ok=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    if changed_hooks:
        hooks_path.parent.mkdir(parents=True, exist_ok=True)

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
        for folder in ("service", "desktop", "macos"):
            replace(staged_lib / folder, lib / folder, folder)
        replace(staged_wrapper, wrapper, "pacemanctl")
        replace(staged_app, APP, "Paceman.app")
        replace(staged_plist, PLIST, "source.plist")
        if not (ROOT / "sharing-paused").exists():
            subprocess.run(["/bin/launchctl", "enable", label], check=True)
            subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(PLIST)], check=True)
        if PUSH_PLIST.is_file():
            replace(None, PUSH_PLIST, "push.plist")
        if changed_hooks:
            replace(staged_hooks, hooks_path, "hooks.json")
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

    try:
        subprocess.run(["/usr/bin/pkill", "-x", "Paceman"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    except OSError:
        pass
    try:
        opened = subprocess.run(["/usr/bin/open", "-n", "-a", str(APP)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        opened = False
    login_marker = ROOT / "menu-login-configured"
    if not login_marker.exists():
        try:
            login = subprocess.run([str(APP / "Contents/MacOS/Paceman"), "--register-login"],
                                   capture_output=True, text=True, timeout=20)
            if login.returncode == 0:
                login_marker.write_text("registered\n")
                login_marker.chmod(0o600)
                print("Paceman menu app will open at login; change this in Manage Paceman.")
            else:
                print("Open at Login needs attention:", login.stderr.strip() or "registration failed")
        except (OSError, subprocess.SubprocessError) as error:
            print("Open at Login needs attention:", error)
    print(f"Installed {APP}")
    print("Mac background activity: one Paceman item for the local source and optional iPhone notifications.")
    print("The Paceman menu-bar app is open." if opened else f"Open the menu app from {APP}.")
    print("Manage Paceman controls whether the menu app opens at login.")
    print("Its Sharing switch pauses the background item;")
    print("Manage Paceman in the panel explains removal and offers Uninstall Paceman.")
    print(f"Control: {wrapper}")
    if not changed_hooks and had_activity:
        print("Codex hooks are installed and have delivered activity before.")
        print("If a new local Codex task does not appear, review Paceman in Codex")
        print("Settings > Hooks (CLI: /hooks) and check pacemanctl status.")
    else:
        print("NEXT: Guide the user through Paceman hook review before testing activity.")
        print_hook_review_steps(wrapper)
    if (ROOT / "private/apns.json").is_file():
        print("The Mac background item also runs the configured iPhone notification worker.")
    else:
        print("To deliver iPhone notifications, the setup agent must locate the existing")
        print("private APNs config/key and run: python3 -m macos.install_push --config CONFIG")
        print("Do not paste the key into chat. See docs/macos.md for verification.")
    paired = 0
    database_path = ROOT / "data/hub.sqlite3"
    if database_path.is_file():
        try:
            with sqlite3.connect(f"file:{database_path}?mode=ro", uri=True) as database:
                paired = database.execute("SELECT COUNT(*) FROM clients").fetchone()[0]
        except sqlite3.Error:
            # The source may not have initialized the database if sharing is off.
            pass
    if paired:
        print(f"Phone pairing preserved: {paired} connected installation{'s' if paired != 1 else ''}.")
    else:
        print("NEXT: Configure private Tailscale Serve HTTPS to 127.0.0.1:8765.")
        print("Then click Paceman's QR button and scan it in the iPhone app's Connect computer flow.")


def print_hook_review_steps(wrapper: Path):
    print("  Codex app: Settings > Hooks > User config (All projects).")
    print("  Codex CLI: enter /hooks, or choose Review hooks at startup.")
    print("  Codex calls each row 'Hook 1'. Identify Paceman by expanding the row")
    print("  and checking its source (User config, ~/.codex/hooks.json) and command:")
    print(f"     {shlex.quote(PYTHON)} {shlex.quote(str(ROOT / 'lib/macos/codex_hook.py'))}")
    print("  Review these seven event rows with the user:")
    for event, purpose in HOOK_PURPOSES:
        print(f"     {event}: {purpose}")
    print("  The script sends only event names and opaque session/turn IDs to the")
    print("  private local Paceman socket; no prompts, replies, transcripts, tool")
    print("  arguments, or project paths. The user decides whether to trust each")
    print("  Paceman row individually. Do not choose Trust all or bypass review.")
    print("  Stay with the user, then send a prompt in a fresh local Codex task")
    print("  and verify lastAgentEventAt advances in:")
    print(f'     "{wrapper}" status')
    print(f"  Until that real event arrives, setup is partial. Full steps: {REPO / 'docs/macos.md'}")


if __name__ == "__main__":
    try:
        install()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Paceman install failed: {error}", file=sys.stderr)
        raise SystemExit(1)
