"""User-exported Mac support report with an explicit, small data allowlist."""
from __future__ import annotations

from collections import deque
from contextlib import closing
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import sqlite3
import time


def report(root: Path, status: dict, app: Path, *, now: float | None = None) -> dict:
    now = time.time() if now is None else now
    database = root / "data/hub.sqlite3"
    source_id = None
    destinations = []
    database_readable = False
    if database.is_file():
        try:
            with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
                row = db.execute("SELECT value FROM metadata WHERE key='source_id'").fetchone()
                source_id = row[0] if row else None
                for table, kind in (("push_devices", "alert"),
                                    ("watch_push_devices", "watch"),
                                    ("live_activities", "live_activity"),
                                    ("live_activity_starts", "live_activity_start")):
                    rows = db.execute(f"SELECT environment,attempts,next_attempt FROM {table}")
                    destinations.extend({"kind": kind, "environment": environment,
                                         "attempts": attempts, "nextAttemptAt": next_attempt}
                                        for environment, attempts, next_attempt in rows)
                database_readable = True
        except sqlite3.Error:
            destinations = []

    version = build = "unknown"
    info = app / "Contents/Info.plist"
    if info.is_file():
        try:
            metadata = plistlib.loads(info.read_bytes())
            version = str(metadata.get("CFBundleShortVersionString", "unknown"))
            build = str(metadata.get("CFBundleVersion", "unknown"))
        except (OSError, ValueError, TypeError):
            pass

    delivery = []
    log = root / "data/push-delivery.jsonl"
    if log.is_file():
        try:
            with log.open(encoding="utf-8") as stream:
                lines = deque(stream, maxlen=100)
            for line in lines:
                try:
                    item = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if not isinstance(item, dict):
                    continue
                stage = item.get("stage")
                if not isinstance(stage, str) or not stage.replace("_", "").isalpha() or len(stage) > 64:
                    continue
                entry = {"stage": stage}
                if type(item.get("at")) in (int, float):
                    entry["at"] = item["at"]
                if type(item.get("status")) is int:
                    entry["status"] = item["status"]
                reason = item.get("reason")
                if isinstance(reason, str) and re.fullmatch(r"[A-Za-z]{1,80}", reason):
                    entry["reason"] = reason
                delivery.append(entry)
        except (OSError, UnicodeError):
            pass

    return {
        "schema": 1,
        "generatedAt": now,
        "platform": "macos",
        "macOSVersion": platform.mac_ver()[0],
        "appVersion": version,
        "build": build,
        "sourceSupportID": hashlib.sha256(source_id.encode()).hexdigest()[:12] if source_id else None,
        "source": {
            "databaseReadable": database_readable,
            "running": bool(status.get("running")),
            "sharingEnabled": bool(status.get("sharingEnabled")),
            "lastAgentEventAt": status.get("lastAgentEventAt") or 0,
            "lastPhoneFetchAt": status.get("lastPhoneFetchAt") or 0,
            "pairedPhones": len(status.get("clients") or []),
            "missingHooks": status.get("missingHooks") or [],
        },
        "push": {
            "configured": (root / "private/apns.json").is_file(),
            "destinations": destinations,
            "recentDelivery": delivery,
        },
    }
