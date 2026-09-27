"""Omarchy allowance record adapter, adapted from Omarchy Watch (MIT).

Reads the existing agents-panel output only. No network polling, credentials,
weather collection, or new account login. Records are source-scoped: the upstream
format supplies no account identity.
"""
import datetime as dt
import json
import math
from pathlib import Path
import re

DATA_FRESH_SECONDS = 1800

def read_codex_allowance(path: Path, epoch: int, *, allow_stale: bool = False) -> dict:
    """Read Omarchy's versioned output, never credentials or transcripts.

    Unknown data is distinct from empty allowance. Reject any unsupported
    window rather than silently presenting one window as overall availability.
    """
    unavailable = {"remaining": 255, "window": 0, "updatedAt": 0, "resetsAt": 0}
    try:
        with path.open() as source:
            raw = source.read(262145)
        if len(raw) > 262144:
            raise ValueError("record too large")
        record = json.loads(raw)
        if (not isinstance(record, dict) or type(record.get("schemaVersion")) is not int or
                record["schemaVersion"] != 1 or record.get("id") != "codex" or
                record.get("usageStatusText") or record.get("retryAdvised")):
            raise ValueError("unsupported record or provider error")
        def timestamp(value):
            if not isinstance(value, str):
                raise ValueError("missing timestamp")
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.utcoffset() is None:
                raise ValueError("timestamp lacks timezone")
            result = int(parsed.timestamp())
            if not 1704067200 <= result <= 3155759999:
                raise ValueError("timestamp outside watch range")
            return result
        updated = timestamp(record.get("updatedAt"))
        if updated > epoch or (not allow_stale and epoch - updated > DATA_FRESH_SECONDS):
            raise ValueError("stale or future-dated record")
        windows = record.get("limits")
        if not isinstance(windows, list) or not windows:
            raise ValueError("no allowance windows")
        candidates = []
        for item in windows:
            if not isinstance(item, dict):
                raise ValueError("invalid window")
            used = item.get("percent")
            if type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 1:
                raise ValueError("invalid used fraction")
            label = item.get("label")
            if label == "Weekly (7-day)":
                window = 1
            elif isinstance(label, str) and re.fullmatch(r"[1-9][0-9]*[hm] window", label):
                window = 2
            else:
                raise ValueError("unsupported allowance window")
            reset = timestamp(item.get("resetsAt"))
            if reset <= updated or (not allow_stale and reset <= epoch):
                raise ValueError("window reset; waiting for fresh limits")
            candidates.append((used, window, reset))
        # Prefer the weekly reading when both windows are equally depleted.
        used, window, reset = max(candidates, key=lambda item: (item[0], item[1] == 1))
        return {"remaining": int(math.floor(100 * (1 - used) + 0.5)),
                "window": window, "updatedAt": updated, "resetsAt": reset}
    except (OSError, ValueError, TypeError, OverflowError, RecursionError) as error:
        return {**unavailable, "reason": str(error)}


def allowance_snapshot(path: Path, epoch: int) -> dict | None:
    value = read_codex_allowance(path, epoch, allow_stale=True)
    if value["remaining"] == 255:
        return None
    return {"provider": "codex", **{key: value[key] for key in
            ("remaining", "window", "updatedAt", "resetsAt")}}
