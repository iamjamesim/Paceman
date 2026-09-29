"""Small, portable HTTPS-behind-proxy APNs relay. Keep its key and registry server-side."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
from socketserver import ThreadingMixIn
from threading import Lock
import time
import unicodedata
import uuid
from wsgiref.simple_server import make_server, WSGIServer

from service.push import APNs, Config
from service.relay_registry import Registry, valid_uuid


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
    if not exact(value, ("sourceID", "clientID", "deviceToken", "environment", "mode", "payload", "headers"),
                 ("activityID",)):
        return False
    token, mode, headers = value["deviceToken"], value["mode"], value["headers"]
    activity_id = value.get("activityID", "")
    if (value["sourceID"] != identity or not valid_uuid(value["clientID"]) or not isinstance(token, str)
            or not re.fullmatch(r"[0-9a-f]{32,512}", token) or len(token) % 2
            or value["environment"] not in ("development", "production")
            or mode not in ("alert", "liveactivity", "watch")
            or not isinstance(activity_id, str)
            or len(activity_id) > 128
            or (mode != "liveactivity" and "activityID" in value)
            or not exact(headers, ("apns-push-type", "apns-priority", "apns-expiration", "apns-id"),
                         ("apns-collapse-id",))):
        return False
    if mode == "liveactivity":
        payload = value["payload"]
        aps = payload.get("aps") if isinstance(payload, dict) else None
        event = aps.get("event") if isinstance(aps, dict) else None
        if (event == "start") != (activity_id == ""):
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
    def __init__(self, sender: APNs, sources: Registry, now=time.time):
        self.sender, self.sources, self.now = sender, sources, now

    def __call__(self, environ, start_response):
        def answer(status, value):
            body = json.dumps(value, separators=(",", ":")).encode()
            start_response(status, [("Content-Type", "application/json"), ("Content-Length", str(len(body))),
                                    ("Cache-Control", "no-store")])
            return [body]
        if environ.get("PATH_INFO") == "/healthz" and environ.get("REQUEST_METHOD") == "GET":
            return answer("200 OK", {"ok": True})
        path, method = environ.get("PATH_INFO"), environ.get("REQUEST_METHOD")
        if (path, method) not in (("/v1/sources", "POST"), ("/v1/sources", "DELETE"),
                                  ("/v1/clients", "PUT"), ("/v1/clients/self", "DELETE"),
                                  ("/v1/destinations", "PUT"),
                                  ("/v1/destinations", "DELETE"), ("/v1/send", "POST")):
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
        candidate = auth.removeprefix("Bearer ") if auth.startswith("Bearer ") else ""
        if not valid_uuid(identity) or not candidate:
            return answer("401 Unauthorized", {"error": "Unauthorized"})
        if path == "/v1/sources" and method == "POST":
            if not exact(value, ("sourceID",)):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            try:
                created = self.sources.create_source(identity, candidate, self.now())
            except ValueError:
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            return answer("200 OK" if created else "409 Conflict", {"registered": created})
        authorized = (self.sources.source_authorized(identity, candidate)
                      if path in ("/v1/clients", "/v1/send", "/v1/sources")
                      else self.sources.client_authorized(identity, value.get("clientID"), candidate))
        if not authorized:
            return answer("401 Unauthorized", {"error": "Unauthorized"})
        if path == "/v1/sources" and method == "DELETE":
            if not exact(value, ("sourceID",)):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            self.sources.delete_source(identity)
            return answer("200 OK", {"revoked": True})
        if path == "/v1/clients":
            if not exact(value, ("sourceID", "clients")):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            try:
                self.sources.sync_clients(identity, value["clients"])
            except ValueError:
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            return answer("200 OK", {"synced": True})
        if path == "/v1/clients/self":
            if not exact(value, ("sourceID", "clientID")):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            self.sources.delete_client(identity, value["clientID"])
            return answer("200 OK", {"revoked": True})
        if path == "/v1/destinations":
            if not exact(value, ("sourceID", "clientID", "mode"),
                         ("activityID", "deviceToken", "environment")):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            activity_id = value.get("activityID", "")
            try:
                if method == "PUT":
                    if not exact(value, ("sourceID", "clientID", "mode", "deviceToken", "environment"),
                                 ("activityID",)):
                        raise ValueError
                    self.sources.bind(identity, value["clientID"], value["mode"], activity_id,
                                      value["deviceToken"], value["environment"])
                else:
                    if not exact(value, ("sourceID", "clientID", "mode"), ("activityID",)):
                        raise ValueError
                    self.sources.unbind(identity, value["clientID"], value["mode"], activity_id)
            except ValueError:
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            return answer("200 OK", {"registered": method == "PUT"})
        if not valid_request(value, identity, self.now()):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        if not self.sources.allowed(identity, value["clientID"], value["mode"],
                                    value["deviceToken"], value["environment"], value.get("activityID", "")):
            return answer("403 Forbidden", {"error": "DestinationNotRegistered"})
        if not self.sources.take_send_slot(identity, self.now()):
            return answer("429 Too Many Requests", {"error": "RateLimited"})
        result = self.sender.send({"token": value["deviceToken"], "environment": value["environment"],
                                   "mode": value["mode"]}, value["payload"], value["headers"], self.now())
        return answer("200 OK", {"status": result.status, "reason": result.reason, "apnsID": result.apns_id})


def application(environ, start_response):
    global _app
    if _app is None:
        with _app_lock:
            if _app is None:
                _app = RelayApp(APNs(Config.load(Path(os.environ["PACEMAN_APNS_CONFIG"]),
                                            require_private_key_permissions=False)),
                                Registry(os.environ["DATABASE_URL"]))
    return _app(environ, start_response)


_app = None
_app_lock = Lock()


class ThreadingWSGIServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apns-config", type=Path, required=True)
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    args = parser.parse_args()
    os.umask(0o077)
    sources = Registry(os.environ["DATABASE_URL"])
    sender = APNs(Config.load(args.apns_config, require_private_key_permissions=False))
    try:
        with make_server("0.0.0.0", args.port, RelayApp(sender, sources),
                         server_class=ThreadingWSGIServer) as server:
            server.serve_forever()
    finally:
        sender.close()


if __name__ == "__main__":
    main()
