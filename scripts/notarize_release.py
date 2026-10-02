"""Persist an Apple submission so a slow notary request can be resumed."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import uuid


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def apple(profile, *args, check=True):
    return subprocess.run(["/usr/bin/xcrun", "notarytool", *map(str, args),
                           "--keychain-profile", profile], capture_output=True, text=True, check=check)


def notarize(dmg: Path, profile: str, context: dict, *, resume=False):
    evidence = dmg.parent / ".notarization"
    receipt = evidence / "submission.json"
    original = evidence / "submitted.dmg"
    if resume:
        state = json.loads(receipt.read_text())
        if state.get("context") != context or digest(original) != state.get("submittedSHA256"):
            raise ValueError("Notarization receipt does not match the requested build or submitted bytes")
        if not state.get("id"):
            raise ValueError("Upload outcome is unknown. Inspect notarytool history before resubmitting; "
                             "the saved candidate will not be uploaded a second time automatically")
        uuid.UUID(state["id"])
    else:
        evidence.mkdir(exist_ok=False)
        shutil.copy2(dmg, original)
        state = {"context": context, "submittedSHA256": digest(original), "status": "Submitting"}
        save(receipt, state)
        submitted = apple(profile, "submit", original, "--output-format", "json", check=False)
        (evidence / "submit-output.txt").write_text(submitted.stdout + submitted.stderr)
        submitted.check_returncode()
        response = json.loads(submitted.stdout)
        uuid.UUID(response["id"])
        state.update(id=response["id"], status="In Progress")
        save(receipt, state)
    print(f"Apple submission {state['id']}; receipt: {receipt}", flush=True)
    # A timeout leaves the server request running. Query its authoritative state
    # after wait returns, including when wait exits nonzero for a rejected upload.
    apple(profile, "wait", state["id"], "--timeout", "5m", "--output-format", "json", check=False)
    info = json.loads(apple(profile, "info", state["id"], "--output-format", "json").stdout)
    state["status"] = info["status"]
    save(receipt, state)
    if state["status"] == "In Progress":
        raise ValueError("Apple is still processing. Resume with the same prepare arguments plus --resume; "
                         "the signed artifact and submission are retained")
    apple(profile, "log", state["id"], evidence / "apple-log.json")
    if state["status"] != "Accepted":
        raise ValueError(f"Apple returned {state['status']}; inspect {evidence / 'apple-log.json'}")
    # Always staple a copy of the exact submitted bytes. An interruption after
    # stapling cannot invalidate the original hash used to resume the request.
    shutil.copy2(original, dmg)
    subprocess.run(["/usr/bin/xcrun", "stapler", "staple", str(dmg)], check=True)
    subprocess.run(["/usr/bin/xcrun", "stapler", "validate", str(dmg)], check=True)
    subprocess.run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context",
                    "context:primary-signature", str(dmg)], check=True)
    state["stapledSHA256"] = digest(dmg)
    save(receipt, state)
