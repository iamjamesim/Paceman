"""Small, portable HTTPS-behind-proxy APNs relay. Keep its key and registry server-side."""
from __future__ import annotations

import argparse
import json
import logging
import os
from pathlib import Path
import re
from socketserver import ThreadingMixIn
from threading import Lock
import time
import unicodedata
import uuid
from wsgiref.simple_server import make_server, WSGIServer

from service.app_attest import AppAttestVerifier
from service.push import APNs, Config
from service.relay_registry import EnrollmentLimited, Registry, valid_uuid


LOG = logging.getLogger("paceman.relay")
LOG.setLevel(logging.INFO)
if not LOG.handlers:
    LOG.addHandler(logging.StreamHandler())
LOG.propagate = False


class APNsRouter:
    """Keep APNs credentials and connections separate for each token environment."""

    def __init__(self, senders: dict[str, APNs]):
        self.senders = senders
        self.environments = frozenset(senders)
        self.app_ids = {environment: f"{sender.config.team_id}.{sender.config.topic}"
                        for environment, sender in senders.items()}

    @classmethod
    def load(cls, path: Path):
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise ValueError("APNs config must be an object")
        if "environments" not in value:
            config = Config.from_value(value, path, require_private_key_permissions=False)
            return cls({config.environment: APNs(config)})
        environments = value["environments"]
        if (set(value) != {"environments"} or not isinstance(environments, dict)
                or not environments or set(environments) - {"development", "production"}):
            raise ValueError("Specify development and/or production APNs configurations")
        senders = {}
        try:
            for environment, item in environments.items():
                config = Config.from_value(item, path, require_private_key_permissions=False)
                if config.environment != environment:
                    raise ValueError("APNs configuration environment does not match its name")
                senders[environment] = APNs(config)
        except Exception:
            for sender in senders.values():
                sender.close()
            raise
        return cls(senders)

    def send(self, device, payload, headers, now):
        return self.senders[device["environment"]].send(device, payload, headers, now)

    def close(self):
        for sender in self.senders.values():
            sender.close()


def exact(value, required, optional=()):
    return isinstance(value, dict) and set(required) <= set(value) and set(value) <= set(required) | set(optional)


def bounded_text(value, limit=160):
    return (isinstance(value, str) and len(value.encode("utf-8")) <= limit
            and all(not unicodedata.category(char).startswith("C") or char in "\u200c\u200d"
                    for char in value))


def valid_payload(mode: str, identity: str, payload: object) -> bool:
    if not exact(payload, ("aps",), ("companion", "schema", "allowance") +
                 (("selectionRevision", "sourceID") if mode == "watch" else ())):
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
        if not exact(payload, ("aps", "schema", "allowance"), ("selectionRevision", "sourceID")) or aps != {"content-available": 1} or payload["schema"] != 1:
            return False
        reading = payload["allowance"]
        return (exact(reading, ("provider", "remaining", "window", "windowDurationMins", "updatedAt", "resetsAt"))
                and reading["provider"] in ("codex", "claude") and all(type(reading[k]) is int for k in
                ("remaining", "window", "windowDurationMins", "updatedAt", "resetsAt"))
                and 0 <= reading["remaining"] <= 100 and reading["window"] in (1, 2)
                and 1 <= reading["windowDurationMins"] <= 10080
                and 0 <= reading["updatedAt"] < reading["resetsAt"] <= 3155759999
                and ("sourceID" not in payload or payload["sourceID"] == identity and valid_uuid(payload["sourceID"]))
                and ("selectionRevision" not in payload or type(payload["selectionRevision"]) is int
                     and 0 <= payload["selectionRevision"] <= 9_007_199_254_740_991))
    if mode == "liveactivity":
        if not exact(payload, ("aps",)) or not exact(aps,
                ("timestamp", "event", "content-state", "stale-date", "relevance-score"),
                ("dismissal-date", "alert", "attributes-type", "attributes", "input-push-token")):
            return False
        state = aps["content-state"]
        if not exact(state, ("schema", "generation", "revision", "state", "working", "needsInput",
                "finished", "failed", "observedAt", "freshUntil", "changedAt"),
                ("providers", "workspaceLabel", "providerStates")):
            return False
        if (state["schema"] != 1 or not bounded_text(state["generation"], 64)
                or state["state"] not in ("idle", "working", "needs_input", "finished", "failed")
                or not all(type(state[k]) is int or type(state[k]) is float for k in
                           ("revision", "working", "needsInput", "finished", "failed", "observedAt", "freshUntil", "changedAt"))
                or ("providers" in state and (not isinstance(state["providers"], list)
                    or len(state["providers"]) > 4 or any(p not in ("codex", "claude", "other") for p in state["providers"])))
                or ("workspaceLabel" in state and not bounded_text(state["workspaceLabel"], 160))):
            return False
        if "providerStates" in state:
            groups = state["providerStates"]
            if (not isinstance(groups, dict) or len(groups) > 3
                    or any(p not in ("codex", "claude", "other") or not exact(counts,
                        ("working", "needs_input", "finished", "failed"))
                        or any(type(n) is not int or not 0 <= n <= 1000 for n in counts.values())
                        for p, counts in groups.items())):
                return False
            for raw, field in (("working", "working"), ("needs_input", "needsInput"), ("finished", "finished"), ("failed", "failed")):
                if sum(c[raw] for c in groups.values()) != state[field]:
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
    def __init__(self, sender: APNsRouter, sources: Registry, now=time.time,
                 verifier: AppAttestVerifier | None = None):
        self.sender, self.sources, self.now, self.verifier = sender, sources, now, verifier

    def __call__(self, environ, start_response):
        def answer(status, value):
            body = json.dumps(value, separators=(",", ":")).encode()
            start_response(status, [("Content-Type", "application/json"), ("Content-Length", str(len(body))),
                                    ("Cache-Control", "no-store")])
            return [body]
        if environ.get("PATH_INFO") == "/healthz" and environ.get("REQUEST_METHOD") == "GET":
            return answer("200 OK", {"ok": True, "apnsEnvironments": sorted(self.sender.environments)})
        path, method = environ.get("PATH_INFO"), environ.get("REQUEST_METHOD")
        if isinstance(path, str) and path.startswith("/v2/"):
            return self.v2(environ, start_response)
        return answer("404 Not Found", {"error": "NotFound"})

    def v2(self, environ, start_response):
        def answer(status, value):
            body = json.dumps(value, separators=(",", ":")).encode()
            start_response(status, [("Content-Type", "application/json"), ("Content-Length", str(len(body))),
                                    ("Cache-Control", "no-store")])
            return [body]
        path, method = environ.get("PATH_INFO"), environ.get("REQUEST_METHOD")
        if (path, method) not in (("/v2/attest/challenge", "POST"), ("/v2/attest/approve", "POST"),
                                  ("/v2/destinations", "PUT"), ("/v2/destinations", "DELETE"),
                                  ("/v2/clients/self", "DELETE"), ("/v2/clients", "DELETE"),
                                  ("/v2/sources", "DELETE"), ("/v2/send", "POST")):
            return answer("404 Not Found", {"error": "NotFound"})
        try:
            size = int(environ.get("CONTENT_LENGTH", ""))
            if not 0 < size <= (32768 if path == "/v2/attest/approve" else 8192):
                raise ValueError
            value = json.loads(environ["wsgi.input"].read(size),
                               parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except (TypeError, ValueError, KeyError):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        if not isinstance(value, dict):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        if path.startswith("/v2/attest/"):
            if self.verifier is None:
                return answer("503 Service Unavailable", {"error": "AttestationUnavailable"})
            fields = ("sourceID", "sourceCredentialHash", "clientID", "clientCredentialHash",
                      "keyID", "environment")
            required = fields if path.endswith("challenge") else (*fields, "kind", "challenge", "proof")
            if not exact(value, required):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            if (not isinstance(value["environment"], str)
                    or value["environment"] not in self.sender.environments):
                return answer("503 Service Unavailable", {"error": "EnvironmentUnavailable"})
            args = [value[key] for key in fields]
            try:
                if path.endswith("challenge"):
                    kind, challenge = self.sources.pairing_challenge(*args, self.now())
                    return answer("200 OK", {"kind": kind, "challenge": challenge})
                self.sources.approve_pairing(*args, value["kind"], value["challenge"],
                                             value["proof"], self.verifier, self.now())
            except EnrollmentLimited:
                LOG.warning("pairing_approval_limited")
                return answer("429 Too Many Requests", {"error": "EnrollmentLimited"})
            except PermissionError:
                LOG.warning("pairing_approval_denied")
                return answer("403 Forbidden", {"error": "PairingDenied"})
            except ValueError as error:
                # The verifier and registry raise fixed, data-free reasons here.
                # Keep credentials, challenges, and proof bytes out of logs.
                LOG.warning("pairing_approval_rejected reason=%s", error)
                return answer("403 Forbidden", {"error": "InvalidAttestation"})
            LOG.info("pairing_approval_accepted")
            return answer("200 OK", {"approved": True})
        source_id, client_id = value.get("sourceID"), value.get("clientID")
        auth = environ.get("HTTP_AUTHORIZATION", "")
        credential = auth.removeprefix("Bearer ") if auth.startswith("Bearer ") else ""
        if not valid_uuid(source_id) or not credential:
            return answer("401 Unauthorized", {"error": "Unauthorized"})
        if path == "/v2/sources":
            if not exact(value, ("sourceID",)):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            if not self.sources.revoke_approved_source(source_id, credential):
                return answer("401 Unauthorized", {"error": "Unauthorized"})
            return answer("200 OK", {"revoked": True})
        if path == "/v2/clients":
            if not exact(value, ("sourceID", "clientID", "clientCredentialHash")) or not valid_uuid(client_id):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            client_hash = value["clientCredentialHash"]
            if not isinstance(client_hash, str) or re.fullmatch(r"[0-9a-f]{64}", client_hash) is None:
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            if not self.sources.revoke_approved_client(source_id, credential, client_id, client_hash):
                return answer("401 Unauthorized", {"error": "Unauthorized"})
            return answer("200 OK", {"revoked": True})
        if not valid_uuid(client_id):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        source_hash = value.get("sourceCredentialHash")
        if path != "/v2/send" and (not isinstance(source_hash, str)
                or re.fullmatch(r"[0-9a-f]{64}", source_hash) is None):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        if path == "/v2/clients/self":
            if not exact(value, ("sourceID", "sourceCredentialHash", "clientID")):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            if not self.sources.revoke_approved_self(source_id, source_hash, client_id, credential):
                return answer("401 Unauthorized", {"error": "Unauthorized"})
            return answer("200 OK", {"revoked": True})
        if path == "/v2/destinations":
            required = ("sourceID", "sourceCredentialHash", "clientID", "mode")
            if not exact(value, (*required, "tokenHash", "environment") if method == "PUT" else required,
                         ("activityID",)):
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            if method == "PUT" and (not isinstance(value["environment"], str)
                                        or value["environment"] not in self.sender.environments):
                return answer("503 Service Unavailable", {"error": "EnvironmentUnavailable"})
            try:
                if method == "PUT":
                    bound = self.sources.bind_approved(source_id, source_hash, client_id, credential,
                        value["mode"], value.get("activityID", ""), value["tokenHash"],
                        value["environment"], self.now())
                else:
                    bound = self.sources.unbind_approved(source_id, source_hash, client_id, credential,
                        value["mode"], value.get("activityID", ""))
            except ValueError:
                return answer("400 Bad Request", {"error": "InvalidRequest"})
            if not bound:
                return answer("401 Unauthorized", {"error": "PairingNotApproved"})
            return answer("200 OK", {"registered": method == "PUT"})
        if not exact(value, ("sourceID", "clientID", "clientCredentialHash", "deviceToken",
                             "environment", "mode", "payload", "headers"), ("activityID",)):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        send_value = {key: item for key, item in value.items() if key != "clientCredentialHash"}
        if not valid_request(send_value, source_id, self.now()):
            return answer("400 Bad Request", {"error": "InvalidRequest"})
        if value["environment"] not in self.sender.environments:
            return answer("503 Service Unavailable", {"error": "EnvironmentUnavailable"})
        if not self.sources.approved_send(source_id, credential, client_id, value["clientCredentialHash"],
                value["mode"], value.get("activityID", ""), value["deviceToken"],
                value["environment"], self.now()):
            return answer("403 Forbidden", {"error": "DestinationNotApproved"})
        if not self.sources.take_send_slot(source_id, self.now()):
            return answer("429 Too Many Requests", {"error": "RateLimited"})
        result = self.sender.send({"token": value["deviceToken"], "environment": value["environment"],
                                   "mode": value["mode"]}, value["payload"], value["headers"], self.now())
        return answer("200 OK", {"status": result.status, "reason": result.reason, "apnsID": result.apns_id})


def application(environ, start_response):
    global _app
    if _app is None:
        with _app_lock:
            if _app is None:
                router = APNsRouter.load(Path(os.environ["PACEMAN_APNS_CONFIG"]))
                _app = RelayApp(router, Registry(os.environ["DATABASE_URL"]),
                                verifier=AppAttestVerifier(router.app_ids))
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
    sender = APNsRouter.load(args.apns_config)
    try:
        with make_server("0.0.0.0", args.port, RelayApp(
                sender, sources, verifier=AppAttestVerifier(sender.app_ids)),
                         server_class=ThreadingWSGIServer) as server:
            server.serve_forever()
    finally:
        sender.close()


if __name__ == "__main__":
    main()
