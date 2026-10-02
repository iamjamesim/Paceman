"""Connect an installed Omarchy source to the project APNs relay."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess

from omarchy import install
from service.hub import Store, endpoint
from service.push import RelayConfig


def configure(relay_url: str, *, app: Path | None = None, state: Path | None = None,
              restart: bool = True, announce: bool = True):
    os.umask(0o077)
    relay_url = endpoint(relay_url)
    home = Path.home()
    app = app or home / ".local/lib/paceman"
    state = state or Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "paceman"
    config = state / "private/apns.json"
    if not (app / "service/push.py").is_file() or not (state / "hub.sqlite3").is_file():
        raise ValueError("Install Paceman first, then configure its relay")
    source_id = Store(state / "hub.sqlite3").metadata("source_id")
    previous = json.loads(config.read_text()) if config.is_file() else None
    if isinstance(previous, dict) and previous.get("sourceID") == source_id and "relayURL" in previous:
        existing = RelayConfig.load(previous)
        value = {"relayURL": relay_url, "sourceID": source_id,
                 "credential": existing.credential}
    else:
        value = {"relayURL": relay_url, "sourceID": source_id,
                 "credential": secrets.token_urlsafe(32)}
    RelayConfig.load(value)
    venv = state / "push-venv"
    python = venv / "bin/python3"
    if not python.is_file():
        subprocess.run(["/usr/bin/python3", "-m", "venv", str(venv)], check=True)
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                    "--require-hashes", "-r", str(install.ROOT / "requirements-client.txt")], check=True)
    subprocess.run([str(python), "-c", "from service.push import RelaySender; import httpx"],
                   cwd=app, check=True)
    install.write(config, (json.dumps(value, separators=(",", ":")) + "\n").encode(), 0o600)
    if restart and not (state / "sharing-paused").exists():
        subprocess.run(["/usr/bin/systemctl", "--user", "restart", install.SERVICE], check=True)
    if announce:
        print("Paceman will send iPhone notifications through the relay while Sharing is on.")
        print("Pair the phone with a fresh QR code so it learns the relay address.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--relay-url", required=True, help="Public HTTPS origin of the Paceman relay")
    args = parser.parse_args()
    try:
        configure(args.relay_url)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(f"Push installation failed: {error}")


if __name__ == "__main__":
    main()
