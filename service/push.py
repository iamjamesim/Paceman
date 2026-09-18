"""Personal APNs provider: reads the local source DB and sends directly to Apple.

No public relay, enrollment service, or inbound internet port. Run alongside
service.hub; the phone registers its destination through the existing paired HTTPS API.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import time
import uuid

from service.hub import Store


@dataclass(frozen=True)
class Config:
    team_id: str
    key_id: str
    topic: str
    environment: str
    private_key: bytes

    @classmethod
    def load(cls, path: Path):
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise ValueError("APNs config must be an object")
        for field in ("teamID", "keyID"):
            if not isinstance(value.get(field), str) or not re.fullmatch(r"[A-Z0-9]{10}", value[field]):
                raise ValueError("teamID and keyID must be 10 uppercase letters/digits")
        if (not isinstance(value.get("topic"), str)
                or not re.fullmatch(r"[A-Za-z0-9.-]{3,200}", value["topic"])
                or value.get("environment") not in ("development", "production")
                or not isinstance(value.get("keyPath"), str)):
            raise ValueError("Specify topic, environment, and keyPath")
        key_path = Path(value["keyPath"]).expanduser()
        if not key_path.is_absolute():
            key_path = path.parent / key_path
        if key_path.stat().st_mode & 0o077:
            raise ValueError("APNs key must be private: chmod 600 its .p8 file")
        return cls(value["teamID"], value["keyID"], value["topic"], value["environment"], key_path.read_bytes())


@dataclass(frozen=True)
class Result:
    status: int
    reason: str
    apns_id: str


def notification(source_id: str, generation: str, event: dict, mode: str, now: float) -> tuple[dict, dict]:
    """Push contains a hint only. The paired HTTPS source remains authoritative."""
    if mode not in ("alert", "background"):
        raise ValueError("Unknown push mode")
    aps = {"content-available": 1}
    if mode == "alert":
        title = "Agent needs input" if event["state"] == "needs_input" else "Agent finished"
        aps.update({"alert": {"title": title, "body": "Open Agent Companion for the latest status."},
                    "sound": "default", "thread-id": source_id})
    payload = {"aps": aps, "companion": {"schema": 1, "sourceID": source_id,
               "generation": generation, "eventID": str(event["seq"]), "revision": event["seq"]}}
    headers = {"apns-push-type": mode, "apns-priority": "10" if mode == "alert" else "5",
               "apns-expiration": str(int(min(now + 300, event["at"] + 300))),
               "apns-collapse-id": source_id, "apns-id": str(uuid.uuid4())}
    return payload, headers


class APNs:
    def __init__(self, config: Config, client=None):
        import httpx
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        key = serialization.load_pem_private_key(config.private_key, password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
            raise ValueError("APNs requires an ES256/P-256 private key")
        self.config, self.key = config, key
        self.client = client or httpx.Client(http2=True, timeout=10, follow_redirects=False, trust_env=False)
        self.jwt = None
        self.issued_at = 0

    def send(self, device: dict, payload: dict, headers: dict, now: float) -> Result:
        import httpx
        import jwt
        if device["environment"] != self.config.environment:
            return Result(0, "EnvironmentMismatch", "")
        if self.jwt is None or now - self.issued_at >= 3000 or now < self.issued_at:
            self.jwt = jwt.encode({"iss": self.config.team_id, "iat": int(now)}, self.key,
                                  algorithm="ES256", headers={"kid": self.config.key_id})
            self.issued_at = now
        host = "api.sandbox.push.apple.com" if self.config.environment == "development" else "api.push.apple.com"
        try:
            response = self.client.post("https://" + host + "/3/device/" + device["token"],
                json=payload, headers={**headers, "apns-topic": self.config.topic,
                                      "authorization": "bearer " + self.jwt})
        except httpx.HTTPError:
            return Result(0, "TransportError", headers["apns-id"])
        # Record bounded APNs codes only, never response bodies, URLs or destination tokens.
        reason = "Accepted" if response.status_code == 200 else "Rejected"
        try:
            candidate = response.json().get("reason", "Rejected")
            if isinstance(candidate, str) and re.fullmatch(r"[A-Za-z]{1,80}", candidate):
                reason = candidate
        except (ValueError, AttributeError):
            pass
        return Result(response.status_code, reason, headers["apns-id"])

    def close(self):
        self.client.close()


class Worker:
    def __init__(self, store: Store, sender, log_path: Path):
        self.store, self.sender, self.log_path = store, sender, log_path

    def step(self, now=None):
        now = time.time() if now is None else now
        self.store.tick(now)
        source_id, generation = self.store.metadata("source_id"), self.store.metadata("generation")
        with self.store.connect() as db:
            # Appearance revisions must not generate activity alerts or hide pending activity.
            event = dict(db.execute("SELECT * FROM events WHERE kind='activity' ORDER BY seq DESC LIMIT 1").fetchone())
            devices = [dict(row) for row in db.execute(
                "SELECT p.* FROM push_devices p JOIN clients c ON p.client_id=c.id WHERE p.cursor<?",
                (event["seq"],))]
        for device in devices:
            # Collapse obsolete intermediate states. Never replay a backlog on reconnect.
            skip = now - event["at"] > 300 or (device["mode"] == "alert" and event["state"] not in ("needs_input", "finished"))
            if skip:
                with self.store.connect() as db:
                    db.execute("UPDATE push_devices SET cursor=?,attempts=0 WHERE client_id=? AND token=? AND mode=?",
                               (event["seq"], device["client_id"], device["token"], device["mode"]))
                continue
            if now < device["next_attempt"]:
                continue
            # Re-check ownership immediately before sending; revocation also removes the destination.
            with self.store.connect() as db:
                current = db.execute("SELECT * FROM push_devices WHERE client_id=?", (device["client_id"],)).fetchone()
            if current is None or dict(current) != device:
                continue
            payload, headers = notification(source_id, generation, event, device["mode"], now)
            result = self.sender.send(device, payload, headers, now)
            invalid = result.status == 410 or result.reason in ("BadDeviceToken", "DeviceTokenNotForTopic")
            retry = result.status in (0, 429, 500, 503) or result.reason == "ExpiredProviderToken"
            # Background-only delivery is deliberately capped at <= 3 attempts/hour.
            minimum = 1201 if device["mode"] == "background" else 10
            delay = max(minimum, min(300, 10 * 2 ** min(device["attempts"], 5))) if retry else minimum
            if result.reason == "EnvironmentMismatch":
                retry, delay = True, max(minimum, 300)
            if result.status in (401, 403):
                retry, delay = True, max(minimum, 300)
            with self.store.connect() as db:
                if invalid:
                    db.execute("DELETE FROM push_devices WHERE client_id=? AND token=?", (device["client_id"], device["token"]))
                else:
                    db.execute("UPDATE push_devices SET cursor=?,next_attempt=?,attempts=?,last_result=?,last_apns_id=? "
                               "WHERE client_id=? AND token=? AND mode=?",
                               (device["cursor"] if retry else event["seq"], now + delay,
                                device["attempts"] + 1 if retry else 0, result.reason, result.apns_id,
                                device["client_id"], device["token"], device["mode"]))
            self.log({"at": now, "event": f"{source_id}/{generation}/{event['seq']}",
                      "clientID": device["client_id"], "mode": device["mode"],
                      "stage": "apns_accepted" if result.status == 200 else "apns_failed",
                      "status": result.status, "reason": result.reason, "apnsID": result.apns_id})

    def log(self, value):
        self.log_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.log_path.exists() and self.log_path.stat().st_size > 2_000_000:
            self.log_path.replace(self.log_path.with_suffix(".previous.jsonl"))
        fd = os.open(self.log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a") as file:
            file.write(json.dumps(value, separators=(",", ":")) + "\n")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path(".runtime"))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--once", action="store_true", help="Process the newest eligible event, then exit")
    args = parser.parse_args()
    store = Store(args.data_dir / "hub.sqlite3")
    # One worker per source DB prevents duplicate sends from accidental double-starts.
    with (args.data_dir / "push.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("A push worker is already running for this data directory")
        try:
            sender = APNs(Config.load(args.config))
        except (ValueError, OSError, ImportError):
            parser.error("Cannot load APNs config/key. Check the config fields, private .p8 permissions, and requirements-push.txt.")
        worker = Worker(store, sender, args.data_dir / "push-delivery.jsonl")
        print("Direct APNs worker running. APNs acceptance is not device delivery or a background wake.", flush=True)
        try:
            while True:
                worker.step()
                if args.once:
                    break
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            sender.close()


if __name__ == "__main__":
    main()
