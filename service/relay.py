"""Small, portable HTTPS-behind-proxy APNs relay. Keep its key and registry server-side."""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
from socketserver import ThreadingMixIn
import time
import unicodedata
import uuid
from wsgiref.simple_server import make_server, WSGIServer

from service.push import APNs, Config


def source_id(value):
    try:
        normalized = str(uuid.UUID(value))
    except (TypeError, ValueError, AttributeError) as error:
        raise ValueError("Invalid source ID") from error
    if normalized != value:
        raise ValueError("Invalid source ID")
    return normalized


def registry(path: Path) -> dict[str, str]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("Invalid source registry")
    for identity, digest in value.items():
        source_id(identity)
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid source registry")
    return value


def enroll(path: Path, identity: str) -> str:
    identity = source_id(identity)
    entries = registry(path) if path.exists() else {}
    credential = secrets.token_urlsafe(32)
    entries[identity] = hashlib.sha256(credential.encode()).hexdigest()
    save_registry(path, entries)
    return credential


def revoke(path: Path, identity: str):
    entries = registry(path)
    entries.pop(source_id(identity), None)
    save_registry(path, entries)


def save_registry(path: Path, entries: dict[str, str]):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(entries, output, sort_keys=True)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def exact(value, required, optional=()):
    return isinstance(value, dict) and set(required) <= set(value) and set(value) <= set(required) | set(optional)


def bounded_text(value, limit=160):
    return (isinstance(value, str) and len(value.encode("utf-8")) <= limit
            and all(not unicodedata.category(char).startswith("C") or char in "\u200c\u200d"
                    for char in value))


def valid_payload(mode: str, identity: str, payload: object) -> bool:
    if not exact(payload, ("aps",), ("companion", "schema", "allowance")):
        return False
    aps = payload["aps"]
    if mode == "alert":
        if not exact(payload, ("aps", "companion")) or not exact(
                aps, ("alert", "thread-id"), ("sound", "interruption-level")):
            return False
        alert = aps["alert"]
        hint = payload["companion"]
        return (exact(alert, ("title", "body")) and all(bounded_text(alert[k], 512) for k in ("title", "body"))
                and aps["thread-id"] == identity and aps.get("sound") in (None, "default")
                and aps.get("interruption-level") in (None, "passive")
                and exact(hint, ("schema", "sourceID", "generation", "eventID", "revision"))
                and hint["schema"] == 1 and hint["sourceID"] == identity
                and bounded_text(hint["generation"], 64) and bounded_text(hint["eventID"], 128)
                and type(hint["revision"]) is int and hint["revision"] >= 0)
    if mode == "watch":
        if not exact(payload, ("aps", "schema", "allowance")) or aps != {"content-available": 1} or payload["schema"] != 1:
            return False
        reading = payload["allowance"]
        return (exact(reading, ("provider", "remaining", "window", "windowDurationMins", "updatedAt", "resetsAt"))
                and reading["provider"] == "codex" and all(type(reading[k]) is int for k in
                ("remaining", "window", "windowDurationMins", "updatedAt", "resetsAt"))
                and 0 <= reading["remaining"] <= 100 and reading["window"] in (1, 2))
    if mode == "liveactivity":
        if not exact(payload, ("aps",)) or not exact(aps,
                ("timestamp", "event", "content-state", "stale-date", "relevance-score"),
                ("dismissal-date", "alert", "attributes-type", "attributes", "input-push-token")):
            return False
        state = aps["content-state"]
        if not exact(state, ("schema", "generation", "revision", "state", "working", "needsInput",
                "finished", "failed", "observedAt", "freshUntil", "changedAt"),
                ("providers", "workspaceLabel")):
            return False
        if (state["schema"] != 1 or not bounded_text(state["generation"], 64)
                or state["state"] not in ("idle", "working", "needs_input", "finished", "failed")
                or not all(type(state[k]) is int or type(state[k]) is float for k in
                           ("revision", "working", "needsInput", "finished", "failed", "observedAt", "freshUntil", "changedAt"))
                or ("providers" in state and (not isinstance(state["providers"], list)
                    or len(state["providers"]) > 4 or any(p not in ("codex", "claude", "other") for p in state["providers"])))
                or ("workspaceLabel" in state and not bounded_text(state["workspaceLabel"], 160))):
            return False
        if (aps["event"] not in ("start", "update", "end") or type(aps["timestamp"]) is not int
                or type(aps["stale-date"]) is not int
                or type(aps["relevance-score"]) not in (int, float)
                or ("dismissal-date" in aps and type(aps["dismissal-date"]) is not int)):
            return False
        if "alert" in aps and (not exact(aps["alert"], ("title", "body"), ("sound",))
                or not all(bounded_text(aps["alert"][k], 512) for k in ("title", "body"))
                or aps["alert"].get("sound") not in (None, "PacemanWorking.wav", "PacemanInput.wav", "PacemanFinished.wav", "PacemanFailed.wav")):
            return False
        if aps["event"] == "start":
            attributes = aps.get("attributes")
            if (aps.get("attributes-type") != "MonitoringActivity" or aps.get("input-push-token") != 1
                    or not exact(attributes, ("sourceID", "sourceName"))
                    or attributes["sourceID"] != identity or not bounded_text(attributes["sourceName"], 240)
                    or not exact(aps.get("alert"), ("title", "body"), ("sound",))):
                return False
        elif any(k in aps for k in ("attributes-type", "attributes", "input-push-token")):
            return False
        return True
    return False


def valid_request(value: object, identity: str, now: float) -> bool:
    if not exact(value, ("sourceID", "deviceToken", "environment", "mode", "payload", "headers")):
        return False
    token, mode, headers = value["deviceToken"], value["mode"], value["headers"]
    if (value["sourceID"] != identity or not isinstance(token, str)
            or not re.fullmatch(r"[0-9a-f]{32,512}", token) or len(token) % 2
            or value["environment"] not in ("development", "production")
            or mode not in ("alert", "liveactivity", "watch")
            or not exact(headers, ("apns-push-type", "apns-priority", "apns-expiration", "apns-id"),
                         ("apns-collapse-id",))):
        return False
    expected_type = "background" if mode == "watch" else mode
    if (headers["apns-push-type"] != expected_type or headers["apns-priority"] not in ("5", "10")
            or not isinstance(headers["apns-id"], str)):
        return False
    try:
        uuid.UUID(headers["apns-id"])
        expiration = int(headers["apns-expiration"])
    except (TypeError, ValueError, AttributeError):
        return False
    if expiration < now - 300 or expiration > now + 3600:
        return False
    collapse = headers.get("apns-collapse-id")
    return ((collapse is None or isinstance(collapse, str) and re.fullmatch(r"[0-9a-f]{64}", collapse))
            and valid_payload(mode, identity, value["payload"]))


class RelayApp:
    def __init__(self, sender: APNs, sources_path: Path, now=time.time):
        self.sender, self.sources_path, self.now = sender, sources_path, now

    def __call__(self, environ, start_response):
        def answer(status, value):
            body = json.dumps(value, separators=(",", ":")).encode()
            start_response(status, [("Content-Type", "application/json"), ("Content-Length", str(len(body))),
                                    ("Cache-Control", "no-store")])
            return [body]
        if environ.get("PATH_INFO") == "/healthz" and environ.get("REQUEST_METHOD") == "GET":
            return answer("200 OK", {"ok": True})
        if environ.get("PATH_INFO") != "/v1/send" or environ.get("REQUEST_METHOD") != "POST":
            return answer("404 Not Found", {"error": "NotFound"})
        try:
            size = int(environ.get("CONTENT_LENGTH", ""))
            if not 0 < size <= 8192:
                raise ValueError
            raw = environ["wsgi.input"].read(size)
            value = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except (TypeError, ValueError, KeyError):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        identity = value.get("sourceID") if isinstance(value, dict) else None
        auth = environ.get("HTTP_AUTHORIZATION", "")
        try:
            entries = registry(self.sources_path)
        except (OSError, ValueError):
            return answer("503 Service Unavailable", {"error": "RegistryUnavailable"})
        try:
            expected = entries.get(source_id(identity))
        except ValueError:
            expected = None
        candidate = auth.removeprefix("Bearer ") if auth.startswith("Bearer ") else ""
        actual = hashlib.sha256(candidate.encode()).hexdigest()
        if not expected or not candidate or not hmac.compare_digest(expected, actual):
            return answer("401 Unauthorized", {"error": "Unauthorized"})
        if not valid_request(value, identity, self.now()):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        result = self.sender.send({"token": value["deviceToken"], "environment": value["environment"],
                                   "mode": value["mode"]}, value["payload"], value["headers"], self.now())
        return answer("200 OK", {"status": result.status, "reason": result.reason, "apnsID": result.apns_id})


def application(environ, start_response):
    global _app
    if _app is None:
        _app = RelayApp(APNs(Config.load(Path(os.environ["PACEMAN_APNS_CONFIG"]),
                                        require_private_key_permissions=False)),
                        Path(os.environ["PACEMAN_RELAY_SOURCES"]))
    return _app(environ, start_response)


_app = None


class ThreadingWSGIServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("enroll", "revoke"):
        command = commands.add_parser(name)
        command.add_argument("--sources", type=Path, required=True)
        command.add_argument("source_id")
    serve = commands.add_parser("serve")
    serve.add_argument("--apns-config", type=Path, required=True)
    serve.add_argument("--sources", type=Path, required=True)
    serve.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "enroll":
        print(enroll(args.sources, args.source_id))
    elif args.command == "revoke":
        revoke(args.sources, args.source_id)
    else:
        registry(args.sources)
        sender = APNs(Config.load(args.apns_config, require_private_key_permissions=False))
        try:
            with make_server("0.0.0.0", args.port, RelayApp(sender, args.sources),
                             server_class=ThreadingWSGIServer) as server:
                server.serve_forever()
        finally:
            sender.close()


if __name__ == "__main__":
    main()
