"""The phone can approve a destination before the Mac ever contacts the relay."""
import io
import json
from pathlib import Path
import secrets
import tempfile
import unittest
import uuid

import httpx

from service.hub import Store
from service.push import (RelayConfig, RelaySender, Result, live_notification,
                          live_start_notification, notification, watch_allowance_notification)
from service.relay import RelayApp
from service.relay_registry import Registry, digest


class FakeAttestation:
    def attest(self, proof, key_id, challenge, environment):
        if proof != "valid-proof":
            raise ValueError("Invalid proof")
        return b"public-key"

    def assert_key(self, proof, public_key, challenge, environment, previous_counter):
        if proof != "valid-proof" or public_key != b"public-key":
            raise ValueError("Invalid proof")
        return previous_counter + 1


class FakeAPNs:
    environments = {"production"}

    def __init__(self):
        self.calls = []

    def send(self, device, payload, headers, now):
        self.calls.append(device)
        return Result(200, "Accepted", headers["apns-id"])


class RelayV2Tests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.registry = Registry("sqlite:///" + str(Path(temporary.name) / "relay.sqlite3"))
        self.sender = FakeAPNs()
        self.now = 100.0
        self.app = RelayApp(self.sender, self.registry, now=lambda: self.now, verifier=FakeAttestation())
        self.source_id, self.client_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.source_secret, self.client_secret = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        self.token = "ab" * 32
        payload, headers = notification(self.source_id, str(uuid.uuid4()),
                                        {"seq": 7, "state": "finished", "at": 100}, 100)
        self.send = {"sourceID": self.source_id, "clientID": self.client_id,
                     "clientCredentialHash": digest(self.client_secret), "deviceToken": self.token,
                     "environment": "production", "mode": "alert", "payload": payload, "headers": headers}

    def call(self, path, body, *, method="POST", credential=""):
        raw = json.dumps(body).encode()
        status = []
        response = self.app({"PATH_INFO": path, "REQUEST_METHOD": method,
                             "CONTENT_LENGTH": str(len(raw)), "wsgi.input": io.BytesIO(raw),
                             "HTTP_AUTHORIZATION": "Bearer " + credential},
                            lambda code, headers: status.append(code))
        return int(status[0].split()[0]), json.loads(b"".join(response))

    def approve(self, *, source_secret=None, client_secret=None, client_id=None, key_id="a" * 43):
        fields = {"sourceID": self.source_id,
                  "sourceCredentialHash": digest(source_secret or self.source_secret),
                  "clientID": client_id or self.client_id,
                  "clientCredentialHash": digest(client_secret or self.client_secret),
                  "keyID": key_id, "environment": "production"}
        status, challenge = self.call("/v2/attest/challenge", fields)
        self.assertEqual(status, 200)
        approval = {**fields, **challenge, "proof": "valid-proof"}
        self.assertEqual(self.call("/v2/attest/approve", approval)[0], 200)
        return approval

    def bind(self, *, token=None, source_secret=None, client_secret=None, client_id=None):
        body = {"sourceID": self.source_id,
                "sourceCredentialHash": digest(source_secret or self.source_secret),
                "clientID": client_id or self.client_id, "mode": "alert",
                "tokenHash": digest(token or self.token), "environment": "production"}
        return self.call("/v2/destinations", body, method="PUT",
                         credential=client_secret or self.client_secret)

    def test_phone_first_then_first_send_confirms_source(self):
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 403)
        self.assertEqual(self.bind()[0], 401)
        self.approve()
        self.assertEqual(self.bind()[0], 200)
        self.assertFalse(self.registry.source_authorized(self.source_id, self.source_secret))
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 200)
        self.assertTrue(self.registry.source_authorized(self.source_id, self.source_secret))
        self.assertEqual(len(self.sender.calls), 1)

    def test_rejected_attestation_logs_reason_without_pairing_secrets(self):
        fields = {"sourceID": self.source_id, "sourceCredentialHash": digest(self.source_secret),
                  "clientID": self.client_id, "clientCredentialHash": digest(self.client_secret),
                  "keyID": "a" * 43, "environment": "production"}
        status, challenge = self.call("/v2/attest/challenge", fields)
        self.assertEqual(status, 200)
        with self.assertLogs("paceman.relay", level="WARNING") as logs:
            status, _ = self.call("/v2/attest/approve", {**fields, **challenge, "proof": "invalid"})
        self.assertEqual(status, 403)
        self.assertIn("pairing_approval_rejected reason=Invalid proof", logs.output[0])
        self.assertNotIn(self.source_secret, logs.output[0])
        self.assertNotIn(self.client_secret, logs.output[0])

    def test_exact_mac_pairing_and_token_are_required(self):
        self.approve()
        self.bind()
        for credential, body in ((secrets.token_urlsafe(32), self.send),
                                 (self.source_secret, {**self.send, "clientCredentialHash": digest("wrong")}),
                                 (self.source_secret, {**self.send, "deviceToken": "cd" * 32}),
                                 (self.source_secret, {**self.send, "environment": "development"})):
            self.assertNotEqual(self.call("/v2/send", body, credential=credential)[0], 200)
        self.assertEqual(self.sender.calls, [])

    def test_phone_cannot_permanently_claim_source_id_with_wrong_secret(self):
        evil_secret = secrets.token_urlsafe(32)
        self.approve(source_secret=evil_secret)
        self.bind(source_secret=evil_secret)
        self.assertEqual(self.call("/v2/sources", {"sourceID": self.source_id}, method="DELETE",
                                   credential=evil_secret)[0], 200)
        self.approve(key_id="b" * 43)
        self.bind()
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", self.send, credential=evil_secret)[0], 403)

    def test_wrong_pending_source_cannot_revoke_real_client(self):
        evil_secret = secrets.token_urlsafe(32)
        self.approve(source_secret=evil_secret)
        self.approve(key_id="b" * 43)
        self.bind()
        revoke = {"sourceID": self.source_id, "clientID": self.client_id,
                  "clientCredentialHash": digest(self.client_secret)}
        self.assertEqual(self.call("/v2/clients", revoke, method="DELETE", credential=evil_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 200)

    def test_replay_rotation_and_explicit_revocation(self):
        approval = self.approve()
        self.assertEqual(self.call("/v2/attest/approve", approval)[0], 403)
        self.bind()
        replacement = "cd" * 32
        self.now = 110
        self.assertEqual(self.bind(token=replacement)[0], 200)
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 200)
        self.now = 711
        self.send["headers"]["apns-expiration"] = str(int(self.now + 300))
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 403)
        rotated = {**self.send, "deviceToken": replacement}
        self.assertEqual(self.call("/v2/send", rotated, credential=self.source_secret)[0], 200)
        revoke = {"sourceID": self.source_id, "clientID": self.client_id,
                  "clientCredentialHash": digest(self.client_secret)}
        self.assertEqual(self.call("/v2/clients", revoke, method="DELETE",
                                   credential=self.source_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", rotated, credential=self.source_secret)[0], 403)
        self.assertEqual(self.call("/v2/attest/approve", approval)[0], 403)
        self.assertEqual(self.bind(token=replacement)[0], 401)

    def test_repair_new_credential_and_source_removal(self):
        self.approve()
        self.bind()
        self.call("/v2/clients", {"sourceID": self.source_id, "clientID": self.client_id,
                                  "clientCredentialHash": digest(self.client_secret)},
                  method="DELETE", credential=self.source_secret)
        new_secret = secrets.token_urlsafe(32)
        self.approve(client_secret=new_secret)
        self.assertEqual(self.bind(client_secret=new_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", {**self.send, "clientCredentialHash": digest(new_secret)},
                                   credential=self.source_secret)[0], 200)
        self.assertEqual(self.call("/v2/sources", {"sourceID": self.source_id}, method="DELETE",
                                   credential=self.source_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", {**self.send, "clientCredentialHash": digest(new_secret)},
                                   credential=self.source_secret)[0], 403)

    def test_mac_sender_and_durable_client_revocation(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        store = Store(Path(temporary.name) / "hub.sqlite3")
        self.source_id = store.metadata("source_id")
        invitation = store.invite("https://computer.example")
        paired = store.redeem(invitation["invitation"], device={
            "installationID": str(uuid.uuid4()), "name": "Phone", "platform": "ios"})
        self.client_id, self.client_secret = paired["clientID"], paired["credential"]
        self.approve()
        self.assertEqual(self.bind()[0], 200)
        payload, headers = notification(self.source_id, str(uuid.uuid4()),
                                        {"seq": 7, "state": "finished", "at": 100}, 100)
        paths = []

        def respond(request):
            paths.append(request.url.path)
            raw = request.content
            status = []
            result = self.app({"PATH_INFO": request.url.path, "REQUEST_METHOD": request.method,
                               "CONTENT_LENGTH": str(len(raw)), "wsgi.input": io.BytesIO(raw),
                               "HTTP_AUTHORIZATION": request.headers.get("authorization", "")},
                              lambda code, headers: status.append(code))
            return httpx.Response(int(status[0].split()[0]), content=b"".join(result))

        sender = RelaySender(RelayConfig("https://relay.example", self.source_id, self.source_secret),
                             httpx.Client(transport=httpx.MockTransport(respond)))
        self.addCleanup(sender.close)
        device = {"client_id": self.client_id, "client_hash": digest(self.client_secret),
                  "token": self.token, "environment": "production"}
        self.assertEqual(sender.send(device, payload, headers, 100).status, 200)
        self.assertEqual(paths, ["/v2/send"])
        self.assertTrue(store.revoke(self.client_id))
        with store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM relay_revocations").fetchone()[0], 1)
        sender.revoke_pending(store)
        with store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM relay_revocations").fetchone()[0], 0)
        self.assertEqual(paths[-1], "/v2/clients")
        self.assertEqual(sender.send(device, payload, headers, 100).reason, "RelayRejected")

    def test_hashes_only_at_rest_and_payload_validation(self):
        self.approve()
        self.bind()
        with self.registry.connection() as db:
            self.assertEqual(db.one("SELECT client_hash FROM relay_approvals WHERE source_id=?",
                                    (self.source_id,))[0], digest(self.client_secret))
            self.assertEqual(db.one("SELECT token_hash FROM relay_approved_destinations WHERE source_id=?",
                                    (self.source_id,))[0], digest(self.token))
        invalid = {**self.send, "payload": {**self.send["payload"], "transcript": "private"}}
        self.assertEqual(self.call("/v2/send", invalid, credential=self.source_secret)[0], 400)
        self.assertEqual(self.sender.calls, [])

    def test_live_activity_and_watch_tokens_are_mode_scoped(self):
        self.approve()
        self.bind()
        snapshot = {"sourceID": self.source_id, "sourceName": "Studio Mac", "generation": str(uuid.uuid4()),
                    "revision": 7, "state": "working", "observedAt": 100, "changedAt": 100,
                    "sessions": [{"state": "working", "provider": "codex"}]}
        start, headers = live_start_notification(snapshot, 100)
        start_send = {**self.send, "mode": "liveactivity", "activityID": "",
                      "payload": start, "headers": headers}
        self.assertEqual(self.call("/v2/send", start_send, credential=self.source_secret)[0], 403)
        start_binding = {"sourceID": self.source_id, "sourceCredentialHash": digest(self.source_secret),
                         "clientID": self.client_id, "mode": "liveactivity", "tokenHash": digest(self.token),
                         "environment": "production"}
        self.assertEqual(self.call("/v2/destinations", start_binding, method="PUT",
                                   credential=self.client_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", start_send, credential=self.source_secret)[0], 200)
        activity_id = str(uuid.uuid4())
        update, headers = live_notification(snapshot, 100)
        update_send = {**start_send, "activityID": activity_id, "payload": update, "headers": headers}
        self.assertEqual(self.call("/v2/send", update_send, credential=self.source_secret)[0], 403)
        self.assertEqual(self.call("/v2/destinations", {**start_binding, "activityID": activity_id},
                                   method="PUT", credential=self.client_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", update_send, credential=self.source_secret)[0], 200)
        watch, headers = watch_allowance_notification(self.source_id, {"provider": "codex",
            "remaining": 42, "window": 2, "windowDurationMins": 300,
            "updatedAt": 100, "resetsAt": 3600}, 100)
        watch_send = {**self.send, "mode": "watch", "payload": watch, "headers": headers}
        self.assertEqual(self.call("/v2/send", watch_send, credential=self.source_secret)[0], 403)
        self.assertEqual(self.call("/v2/destinations", {**start_binding, "mode": "watch"},
                                   method="PUT", credential=self.client_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", watch_send, credential=self.source_secret)[0], 200)

    def test_phone_can_unbind_and_revoke_itself(self):
        self.approve()
        self.bind()
        base = {"sourceID": self.source_id, "sourceCredentialHash": digest(self.source_secret),
                "clientID": self.client_id}
        self.assertEqual(self.call("/v2/destinations", {**base, "mode": "alert"},
                                   method="DELETE", credential=self.client_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 403)
        self.bind()
        self.assertEqual(self.call("/v2/clients/self", base, method="DELETE",
                                   credential=self.client_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 403)

    def test_send_limits_apply_after_first_send(self):
        self.approve()
        self.bind()
        for _ in range(120):
            self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 200)
        self.assertEqual(self.call("/v2/send", self.send, credential=self.source_secret)[0], 429)
        self.assertEqual(len(self.sender.calls), 120)

    def test_repair_queues_old_credential_until_relay_acknowledges_revocation(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        store = Store(Path(temporary.name) / "hub.sqlite3")
        installation_id = str(uuid.uuid4())
        device = {"installationID": installation_id, "name": "Phone", "platform": "ios"}
        first = store.redeem(store.invite("https://computer.example")["invitation"], device=device)
        second = store.redeem(store.invite("https://computer.example")["invitation"],
                              device=device, previous_token=first["credential"])
        self.assertEqual(second["clientID"], first["clientID"])
        self.assertNotEqual(second["credential"], first["credential"])
        with store.connect() as db:
            self.assertEqual(db.execute("SELECT client_hash FROM relay_revocations").fetchone()[0],
                             digest(first["credential"]))
        status = 503
        calls = []

        def respond(request):
            calls.append(request.url.path)
            return httpx.Response(status)

        sender = RelaySender(RelayConfig("https://relay.example", store.metadata("source_id"),
                                         secrets.token_urlsafe(32)),
                             httpx.Client(transport=httpx.MockTransport(respond)))
        self.addCleanup(sender.close)
        sender.revoke_pending(store, 100)
        self.assertEqual(calls, ["/v2/clients"])
        sender.revoke_pending(store, 101)
        self.assertEqual(calls, ["/v2/clients"])
        status = 200
        sender.revoke_pending(store, 102)
        self.assertEqual(calls, ["/v2/clients", "/v2/clients"])
        with store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM relay_revocations").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
