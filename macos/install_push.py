"""Install the personal APNs worker for an already installed Paceman Mac source."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile

from macos.install import LABEL as SOURCE_LABEL, PLIST as SOURCE_PLIST
from macos.install import PUSH_LABEL as LABEL, PUSH_PLIST as PLIST
from macos.install import REPO, ROOT, runtime_python
from service.hub import Store, endpoint
from service.push import Config, RelayConfig

LABEL = "dev.paceman.push"
PLIST = Path.home() / "Library/LaunchAgents/dev.paceman.push.plist"
PRIVATE = ROOT / "private"
KEY = PRIVATE / "apns-key.p8"
CONFIG = PRIVATE / "apns.json"
WATCH_KEY = PRIVATE / "apns-watch-key.p8"
VENV = ROOT / "push-venv"


def install(config_path: Path | None = None, *, relay_url: str | None = None):
    os.umask(0o077)
    if (config_path is None) == (relay_url is None):
        raise ValueError("Specify exactly one of --config or --relay-url")
    if relay_url is not None:
        relay_url = endpoint(relay_url)
    if config_path is not None:
        config_path = config_path.expanduser().resolve()
    if not (ROOT / "lib/service/push.py").is_file() or not (ROOT / "data/hub.sqlite3").is_file():
        raise ValueError("Install and pair the Paceman Mac source first")
    arguments = plistlib.loads(SOURCE_PLIST.read_bytes()).get("ProgramArguments", []) if SOURCE_PLIST.is_file() else []
    if not arguments or "PacemanBackground" not in arguments[0]:
        raise ValueError("Update the Mac app with macos/install.py before adding notifications")
    if relay_url is not None:
        source_id = Store(ROOT / "data/hub.sqlite3").metadata("source_id")
        previous = json.loads(CONFIG.read_text()) if CONFIG.is_file() else None
        if isinstance(previous, dict) and previous.get("sourceID") == source_id and "relayURL" in previous:
            existing = RelayConfig.load(previous)
            raw = {"relayURL": relay_url, "sourceID": source_id,
                   "credential": existing.credential}
        else:
            raw = {"relayURL": relay_url, "sourceID": source_id,
                   "credential": secrets.token_urlsafe(32)}
    else:
        raw = json.loads(config_path.read_text())
    if not isinstance(raw, dict):
        raise ValueError("Push config must be an object")
    relay = RelayConfig.load(raw) if "relayURL" in raw else None
    validated = None if relay else Config.load(config_path)
    if relay and relay.source_id != Store(ROOT / "data/hub.sqlite3").metadata("source_id"):
        raise ValueError("Relay sourceID does not match the paired source database")

    PRIVATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    PRIVATE.chmod(0o700)
    if relay:
        value = raw
    else:
        source_key = Path(raw["keyPath"]).expanduser()
        if not source_key.is_absolute():
            source_key = config_path.parent / source_key
        source_key = source_key.resolve()
        if source_key != KEY:
            shutil.copyfile(source_key, KEY)
        KEY.chmod(0o600)
        if validated.watch_key_id:
            watch_source = Path(raw["watchKeyPath"]).expanduser()
            if not watch_source.is_absolute():
                watch_source = config_path.parent / watch_source
            if watch_source.resolve() != WATCH_KEY:
                shutil.copyfile(watch_source, WATCH_KEY)
            WATCH_KEY.chmod(0o600)
        value = {"teamID": validated.team_id, "keyID": validated.key_id,
                 "topic": validated.topic, "environment": validated.environment,
                 "keyPath": str(KEY)}
        if validated.watch_key_id:
            value.update(watchKeyID=validated.watch_key_id, watchKeyPath=str(WATCH_KEY))
    descriptor, name = tempfile.mkstemp(prefix=".apns-", dir=PRIVATE)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output)
            output.write("\n")
        temporary.replace(CONFIG)
    finally:
        temporary.unlink(missing_ok=True)
    CONFIG.chmod(0o600)

    python = VENV / "bin/python3"
    if not python.is_file():
        subprocess.run([runtime_python(), "-m", "venv", str(VENV)], check=True)
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                    "-r", str(REPO / "requirements-push.txt")], check=True)
    check = ("from pathlib import Path; from service.push import RelaySender, RelayConfig; "
             "import json; RelaySender(RelayConfig.load(json.loads(Path('private/apns.json').read_text()))).close()"
             if relay else
             "from pathlib import Path; from service.push import APNs, Config; "
             "APNs(Config.load(Path('private/apns.json'))).close()")
    subprocess.run([str(python), "-c", check], cwd=ROOT,
                   env={**os.environ, "PYTHONPATH": str(ROOT / "lib")}, check=True)
    if relay:
        # Switching an existing alpha installation must not leave our APNs key behind.
        KEY.unlink(missing_ok=True)
        WATCH_KEY.unlink(missing_ok=True)

    if validated and validated.watch_key_id:
        with sqlite3.connect(ROOT / "data/hub.sqlite3") as db:
            db.execute("UPDATE watch_push_devices SET next_attempt=0,attempts=0")

    if PLIST.is_file():
        if plistlib.loads(PLIST.read_bytes()).get("Label") != LABEL:
            raise ValueError(f"Refusing to replace unrelated background item at {PLIST}")
        subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        PLIST.unlink()
    if not (ROOT / "sharing-paused").exists():
        subprocess.run(["/bin/launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{SOURCE_LABEL}"],
                       check=True)
    print("iPhone notifications enabled in Paceman's single Mac background item.")
    print("The relay credential is stored in Paceman Application Support; the APNs key remains server-side."
          if relay else "The private key and config are stored in Paceman Application Support.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--config", type=Path, help="Existing private APNs JSON config")
    selection.add_argument("--relay-url", help="Public HTTPS origin for automatic relay enrollment")
    args = parser.parse_args()
    try:
        install(args.config, relay_url=args.relay_url)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(f"Push installation failed: {error}")


if __name__ == "__main__":
    main()
