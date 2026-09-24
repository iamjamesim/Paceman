"""Personal APNs provider: reads the local source DB and sends directly to Apple.

No public relay, enrollment service, or inbound internet port. Run alongside
service.hub; the phone registers its destination through the existing paired HTTPS API.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import fcntl
import hashlib
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


def notification_copy(event: dict) -> dict:
    # Only bounded source/provider/state metadata goes on the lock screen.
    # Never include event labels, prompts, paths or transcript content.
    raw = event.get("payload")
    value = json.loads(raw) if raw else {}
    source = value.get("sourceName", "Computer")
    source = " ".join(str(source).split())[:64] or "Computer"
    sessions = value.get("sessions", [])
    matching = [s for s in sessions if s.get("state") == event["state"]]
    providers = {"codex": "Codex", "claude": "Claude", "claude-code": "Claude"}
    subject = providers.get(matching[0].get("provider"), "Agent") if len(matching) == 1 else "Agent"
    titles = {"working": f"{subject} is working", "needs_input": f"{subject} needs input",
              "finished": f"{subject} finished its turn", "idle": "No active sessions"}
    if len(matching) > 1:
        count = len(matching)
        titles.update(working=f"{count} sessions are working",
                      needs_input=f"{count} sessions need input",
                      finished=f"{count} sessions finished their turns")
    counts = [(state, sum(s.get("state") == state for s in sessions))
              for state in ("needs_input", "working", "finished")]
    labels = {"needs_input": "need input", "working": "working", "finished": "finished"}
    summary = " · ".join(f"{n} {labels[state]}" for state, n in counts if n and state != event["state"])
    body = source + (" · " + summary if len(sessions) > 1 and summary else "")
    return {"title": titles[event["state"]], "body": body}


def notification(source_id: str, generation: str, event: dict, now: float) -> tuple[dict, dict]:
    """Push contains a hint only. The paired HTTPS source remains authoritative."""
    if event["state"] not in ("working", "idle", "needs_input", "finished"):
        raise ValueError("Unknown activity state")
    passive = event["state"] in ("working", "idle")
    aps = {"alert": notification_copy(event), "thread-id": source_id}
    if passive:
        aps["interruption-level"] = "passive"
    else:
        aps["sound"] = "default"
    payload = {"aps": aps, "companion": {"schema": 1, "sourceID": source_id,
               "generation": generation, "eventID": str(event["seq"]), "revision": event["seq"]}}
    # Retain distinct activity events in Notification Center. Retries reuse the
    # same identity; thread-id groups events without replacing earlier entries.
    identity = json.dumps([source_id, generation, str(event["seq"])], separators=(",", ":"))
    collapse_id = hashlib.sha256(identity.encode()).hexdigest()
    headers = {"apns-push-type": "alert", "apns-priority": "10",
               "apns-expiration": str(int(min(now + 300, event["at"] + 300))),
               "apns-collapse-id": collapse_id, "apns-id": str(uuid.uuid4())}
    return payload, headers


def live_notification(snapshot: dict, now: float, ending=False) -> tuple[dict, dict]:
    """Display-only envelope shared with MonitoringActivity.ContentState; no private text."""
    sessions = snapshot.get("sessions") or []
    counts = {state: sum(s.get("state") == state for s in sessions) for state in ("working", "needs_input", "finished")}
    if not sessions and snapshot["state"] in counts:
        counts[snapshot["state"]] = 1
    observed = min(now, snapshot["observedAt"])
    # A source-side renewal every four minutes keeps an unchanged active state
    # current. If its worker disappears, ActivityKit marks it stale after five.
    fresh_until = observed + 300
    content = {"schema": 1, "generation": snapshot["generation"], "revision": snapshot["revision"],
               "state": snapshot["state"], "working": counts["working"], "needsInput": counts["needs_input"],
               "finished": counts["finished"], "observedAt": observed, "freshUntil": fresh_until,
               "changedAt": snapshot["changedAt"]}
    attention = 240 if counts["needs_input"] else 60 if counts["working"] else 0
    aps = {"timestamp": int(now), "event": "end" if ending else "update", "content-state": content,
           "stale-date": int(fresh_until), "relevance-score": (observed + attention) / 10_000_000}
    if ending:
        aps["dismissal-date"] = int(now)
    return {"aps": aps}, {"apns-push-type": "liveactivity", "apns-priority": "5",
        "apns-expiration": str(int(now + 60)), "apns-id": str(uuid.uuid4())}


def live_start_notification(snapshot: dict, now: float) -> tuple[dict, dict]:
    """Start one computer's activity; Apple requires a visible start alert."""
    payload, headers = live_notification(snapshot, now)
    source = " ".join(str(snapshot.get("sourceName", "Computer")).split())[:64] or "Computer"
    payload["aps"].update({"event": "start", "attributes-type": "MonitoringActivity",
        "attributes": {"sourceID": snapshot["sourceID"], "sourceName": source},
        "input-push-token": 1,
        "alert": {"title": "Paceman is following " + source,
                  "body": "Live agent activity is available on your Lock Screen."}})
    headers["apns-priority"] = "10"
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
                json=payload, headers={**headers, "apns-topic": self.config.topic + (".push-type.liveactivity" if device.get("mode") == "liveactivity" else ""),
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
        self.step_live_activities(now)
        source_id, generation = self.store.metadata("source_id"), self.store.metadata("generation")
        with self.store.connect() as db:
            # Appearance revisions must not generate activity alerts or hide pending activity.
            event = dict(db.execute("SELECT * FROM events WHERE kind='activity' ORDER BY seq DESC LIMIT 1").fetchone())
            devices = [dict(row) for row in db.execute(
                "SELECT p.* FROM push_devices p JOIN clients c ON p.client_id=c.id WHERE p.cursor<?",
                (event["seq"],))]
        for device in devices:
            # Collapse obsolete intermediate states. Never replay a backlog on reconnect.
            if now - event["at"] > 300:
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
            payload, headers = notification(source_id, generation, event, now)
            result = self.sender.send(device, payload, headers, now)
            invalid = result.status == 410 or result.reason in ("BadDeviceToken", "DeviceTokenNotForTopic")
            retry = result.status in (0, 429, 500, 503) or result.reason == "ExpiredProviderToken"
            minimum = 10
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
                      "presentation": payload["aps"].get("interruption-level", "active"),
                      "stage": "apns_accepted" if result.status == 200 else "apns_failed",
                      "status": result.status, "reason": result.reason, "apnsID": result.apns_id})

    def step_live_activities(self, now):
        snapshot = self.store.snapshot()
        self.step_live_starts(snapshot, now)
        with self.store.connect() as db:
            devices = [dict(row) for row in db.execute(
                "SELECT l.* FROM live_activities l JOIN clients c ON l.client_id=c.id")]
        for device in devices:
            ending = (now >= device["expires"] or snapshot["state"] == "idle"
                      or (snapshot["state"] == "finished" and now - snapshot["changedAt"] >= 90))
            changed = device["cursor"] < snapshot["revision"]
            due = now >= device["next_attempt"]
            heartbeat = not changed and due and now >= device["next_attempt"] + 225
            if not ending and not (due and (changed or heartbeat)):
                continue
            if ending and not due:
                continue
            # A rotated token, replacement activity or revoked pairing invalidates this send.
            with self.store.connect() as db:
                current = db.execute("SELECT * FROM live_activities WHERE client_id=?", (device["client_id"],)).fetchone()
                authorized = db.execute("SELECT 1 FROM clients WHERE id=?", (device["client_id"],)).fetchone()
            if not authorized or current is None or dict(current) != device:
                continue
            payload, headers = live_notification(snapshot, now, ending=ending)
            result = self.sender.send({**device, "mode": "liveactivity"}, payload, headers, now)
            invalid = result.status == 410 or result.reason in ("BadDeviceToken", "DeviceTokenNotForTopic")
            accepted = result.status == 200
            with self.store.connect() as db:
                if invalid or (ending and accepted) or now > device["expires"] + 300:
                    db.execute("DELETE FROM live_activities WHERE client_id=? AND token=? AND activity_id=?",
                               (device["client_id"], device["token"], device["activity_id"]))
                    if ending and accepted:
                        db.execute("UPDATE live_activity_starts SET cursor=?,next_attempt=0 WHERE client_id=?",
                                   (snapshot["revision"], device["client_id"]))
                else:
                    delay = 15 if accepted else min(300, 15 * 2 ** min(device["attempts"], 5))
                    retry_cursor = min(device["cursor"], snapshot["revision"] - 1)
                    db.execute("UPDATE live_activities SET cursor=?,next_attempt=?,attempts=? WHERE client_id=? AND token=? AND activity_id=?",
                               (snapshot["revision"] if accepted else retry_cursor, now + delay,
                                0 if accepted else device["attempts"] + 1, device["client_id"], device["token"], device["activity_id"]))
            self.log({"at": now, "stage": "live_activity_apns_accepted" if accepted else "live_activity_apns_failed",
                      "revision": snapshot["revision"], "status": result.status, "reason": result.reason})

    def step_live_starts(self, snapshot, now):
        if snapshot["state"] == "idle" or (snapshot["state"] == "finished"
                and now - snapshot["changedAt"] >= 90):
            # A successful remote start reserves this source for one active run.
            # The update token may arrive later; revisions must not start copies.
            with self.store.connect() as db:
                db.execute("UPDATE live_activity_starts SET cursor=?,next_attempt=0",
                           (snapshot["revision"],))
            return
        if (snapshot["state"] not in ("working", "needs_input")
                or now >= snapshot["observedAt"] + snapshot["freshFor"]):
            return
        with self.store.connect() as db:
            devices = [dict(row) for row in db.execute(
                "SELECT s.* FROM live_activity_starts s JOIN clients c ON s.client_id=c.id "
                "LEFT JOIN live_activities l ON l.client_id=s.client_id "
                "WHERE l.client_id IS NULL AND s.cursor<? AND s.next_attempt<=?",
                (snapshot["revision"], now))]
        for device in devices:
            with self.store.connect() as db:
                current = db.execute("SELECT * FROM live_activity_starts WHERE client_id=?", (device["client_id"],)).fetchone()
                active = db.execute("SELECT 1 FROM live_activities WHERE client_id=?", (device["client_id"],)).fetchone()
            if active or current is None or dict(current) != device:
                continue
            payload, headers = live_start_notification(snapshot, now)
            result = self.sender.send({**device, "mode": "liveactivity"}, payload, headers, now)
            accepted = result.status == 200
            invalid = result.status == 410 or result.reason in ("BadDeviceToken", "DeviceTokenNotForTopic")
            with self.store.connect() as db:
                if invalid:
                    db.execute("DELETE FROM live_activity_starts WHERE client_id=? AND token=?",
                               (device["client_id"], device["token"]))
                else:
                    delay = 8 * 3600 if accepted else min(300, 15 * 2 ** min(device["attempts"], 5))
                    db.execute("UPDATE live_activity_starts SET cursor=?,next_attempt=?,attempts=? "
                               "WHERE client_id=? AND token=?",
                               (snapshot["revision"] if accepted else device["cursor"], now + delay,
                                0 if accepted else device["attempts"] + 1,
                                device["client_id"], device["token"]))
            self.log({"at": now, "stage": "live_activity_start_accepted" if accepted else "live_activity_start_failed",
                      "revision": snapshot["revision"], "status": result.status, "reason": result.reason})

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
