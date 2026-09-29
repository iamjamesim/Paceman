import io
import json
from pathlib import Path
import plistlib
import secrets
import tempfile
import unittest
import uuid
from unittest.mock import patch

import macos.install_push as mac_push
import macos.uninstall as mac_uninstall

from service.hub import Store
from service.push import (RelayConfig, RelaySender, Result, live_notification,
                          live_start_notification, notification, watch_allowance_notification)
from service.relay import RelayApp
from service.relay_registry import Registry, digest


class FakeAPNs:
    def __init__(self):
        self.calls = []

    def send(self, device, payload, headers, now):
        self.calls.append(device)
        return Result(200, "Accepted", headers["apns-id"])


class PublicRelayTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.registry = Registry("sqlite:///" + str(Path(temporary.name) / "relay.sqlite3"))
        self.source, self.other, self.client_id = (str(uuid.uuid4()) for _ in range(3))
        self.source_key, self.other_key, self.phone_key = (secrets.token_urlsafe(32) for _ in range(3))
        self.registry.create_source(self.source, self.source_key, 100)
        self.registry.create_source(self.other, self.other_key, 100)
        self.registry.sync_clients(self.source, [{"clientID": self.client_id,
                                                  "credentialHash": digest(self.phone_key)}])
        self.token = "ab" * 32
        self.registry.bind(self.source, self.client_id, "alert", "", self.token, "production")
        self.sender = FakeAPNs()
        self.app = RelayApp(self.sender, self.registry, now=lambda: 100)
        payload, headers = notification(self.source, str(uuid.uuid4()),
                                        {"seq": 7, "state": "finished", "at": 100}, 100)
        self.request = {"sourceID": self.source, "clientID": self.client_id,
                        "deviceToken": self.token, "environment": "production", "mode": "alert",
                        "payload": payload, "headers": headers}

    def call(self, path="/v1/send", method="POST", body=None, credential=None):
        raw = json.dumps(self.request if body is None else body).encode()
        status = []
        response = self.app({"PATH_INFO": path, "REQUEST_METHOD": method,
                             "CONTENT_LENGTH": str(len(raw)), "wsgi.input": io.BytesIO(raw),
                             "HTTP_AUTHORIZATION": "Bearer " + (credential or self.source_key)},
                            lambda result, headers: status.append(result))
        return int(status[0].split()[0]), json.loads(b"".join(response))

    def binding(self, source=None):
        return {"sourceID": source or self.source, "clientID": self.client_id, "mode": "alert",
                "deviceToken": self.token, "environment": "production"}

    def test_self_registration_and_phone_binding(self):
        third, key = str(uuid.uuid4()), secrets.token_urlsafe(32)
        self.assertEqual(self.call("/v1/sources", body={"sourceID": third}, credential=key)[0], 200)
        self.assertEqual(self.call("/v1/sources", body={"sourceID": third}, credential="x" * 43)[0], 409)
        self.assertEqual(self.call("/v1/clients", "PUT", {"sourceID": third,
            "clients": [{"clientID": self.client_id, "credentialHash": digest(self.phone_key)}]}, key)[0], 200)
        self.assertEqual(self.call("/v1/destinations", "PUT", self.binding(third), self.phone_key)[0], 200)
        self.assertTrue(self.registry.allowed(third, self.client_id, "alert", self.token, "production"))

    def test_send_requires_source_and_exact_destination(self):
        self.assertEqual(self.call()[0], 200)
        self.assertEqual(self.sender.calls[0]["token"], self.token)
        self.assertEqual(self.call(body={**self.request, "deviceToken": "cd" * 32})[0], 403)
        self.assertEqual(self.call(body={**self.request, "environment": "development"})[0], 403)
        self.assertEqual(self.call(credential=self.other_key)[0], 401)
        self.assertEqual(self.call(body={**self.request, "sourceID": self.other}, credential=self.other_key)[0], 400)
        self.assertEqual(len(self.sender.calls), 1)

    def test_phone_cannot_bind_another_client(self):
        self.assertEqual(self.call("/v1/destinations", "PUT", {**self.binding(),
            "clientID": str(uuid.uuid4())}, self.phone_key)[0], 401)
        self.assertEqual(self.call("/v1/destinations", "PUT", self.binding(self.other), self.phone_key)[0], 401)
        self.assertEqual(self.call("/v1/destinations", "PUT", self.binding(), self.other_key)[0], 401)

    def test_rotation_and_revocation_clear_bindings(self):
        rotated = secrets.token_urlsafe(32)
        self.registry.sync_clients(self.source, [{"clientID": self.client_id,
                                                  "credentialHash": digest(rotated)}])
        self.assertEqual(self.call()[0], 403)
        self.assertEqual(self.call("/v1/destinations", "PUT", self.binding(), self.phone_key)[0], 401)
        self.assertEqual(self.call("/v1/destinations", "PUT", self.binding(), rotated)[0], 200)
        self.registry.sync_clients(self.source, [])
        self.assertEqual(self.call()[0], 403)
        self.assertEqual(self.call("/v1/sources", "DELETE", {"sourceID": self.source})[0], 200)
        self.assertEqual(self.call()[0], 401)
        self.assertEqual(self.call("/v1/sources", body={"sourceID": self.source})[0], 409)
        self.assertEqual(self.call("/v1/sources", body={"sourceID": self.source},
                                   credential=secrets.token_urlsafe(32))[0], 409)
        self.assertTrue(self.registry.source_authorized(self.other, self.other_key))

    def test_payload_rejects_transcripts_and_topic_override(self):
        for changed in ({**self.request, "payload": {**self.request["payload"], "transcript": "private"}},
                        {**self.request, "headers": {**self.request["headers"], "apns-topic": "other"}}):
            self.assertEqual(self.call(body=changed)[0], 400)
        self.assertEqual(self.sender.calls, [])

    def test_live_start_and_update_have_separate_bindings(self):
        snapshot = {"sourceID": self.source, "sourceName": "Studio Mac", "generation": str(uuid.uuid4()),
                    "revision": 7, "state": "working", "observedAt": 100, "changedAt": 100,
                    "sessions": [{"state": "working", "provider": "codex"}]}
        start, headers = live_start_notification(snapshot, 100)
        self.registry.bind(self.source, self.client_id, "liveactivity", "", self.token, "production")
        self.assertEqual(self.call(body={**self.request, "mode": "liveactivity", "payload": start,
                                        "headers": headers, "activityID": ""})[0], 200)
        update, headers = live_notification(snapshot, 100)
        activity_id = str(uuid.uuid4())
        update_request = {**self.request, "mode": "liveactivity", "payload": update,
                          "headers": headers, "activityID": activity_id}
        self.assertEqual(self.call(body=update_request)[0], 403)
        self.registry.bind(self.source, self.client_id, "liveactivity", activity_id, self.token, "production")
        self.assertEqual(self.call(body=update_request)[0], 200)

    def test_watch_token_is_scoped_to_watch_mode(self):
        watch, headers = watch_allowance_notification(self.source, {"provider": "codex",
            "remaining": 42, "window": 2, "windowDurationMins": 300,
            "updatedAt": 100, "resetsAt": 3600}, 100)
        request = {**self.request, "mode": "watch", "payload": watch, "headers": headers}
        self.assertEqual(self.call(body=request)[0], 403)
        self.registry.bind(self.source, self.client_id, "watch", "", self.token, "production")
        self.assertEqual(self.call(body=request)[0], 200)
        self.assertEqual(self.call(body={**request, "payload": {**watch, "prompt": "private"}})[0], 400)

    def test_source_config_requires_https_and_random_credential(self):
        value = {"relayURL": "https://relay.example", "sourceID": self.source,
                 "credential": self.source_key}
        self.assertEqual(RelayConfig.load(value).source_id, self.source)
        for bad in ({**value, "relayURL": "http://relay.example"},
                    {**value, "relayURL": "https://user@relay.example"},
                    {**value, "credential": "short"}, {**value, "keyPath": "secret.p8"}):
            with self.assertRaises(ValueError):
                RelayConfig.load(bad)

    def test_database_stores_hashes_only(self):
        with self.registry.connection() as db:
            self.assertEqual(db.one("SELECT credential_hash FROM relay_sources WHERE id=?",
                                    (self.source,))[0], digest(self.source_key))
            self.assertEqual(db.one("SELECT token_hash FROM relay_destinations WHERE source_id=?",
                                    (self.source,))[0], digest(self.token))

    def test_per_source_send_limit(self):
        for _ in range(120):
            self.assertEqual(self.call()[0], 200)
        self.assertEqual(self.call()[0], 429)
        self.assertEqual(len(self.sender.calls), 120)

    def test_global_send_limit_bounds_open_enrollment(self):
        self.assertTrue(self.registry.take_send_slot(self.source, 100, global_per_minute=1))
        self.assertFalse(self.registry.take_send_slot(self.other, 100, global_per_minute=1))
        self.assertTrue(self.registry.take_send_slot(self.other, 160, global_per_minute=1))

    def test_mac_syncs_pairings_before_sending(self):
        import httpx
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        store = Store(Path(temporary.name) / "hub.sqlite3")
        identity = store.metadata("source_id")
        source_key = secrets.token_urlsafe(32)
        invitation = store.invite("https://computer.example")
        paired = store.redeem(invitation["invitation"], device={"installationID": str(uuid.uuid4()),
            "name": "Phone", "platform": "ios"})

        def respond(request):
            statuses = []
            raw = request.content
            value = self.app({"PATH_INFO": request.url.path, "REQUEST_METHOD": request.method,
                "CONTENT_LENGTH": str(len(raw)), "wsgi.input": io.BytesIO(raw),
                "HTTP_AUTHORIZATION": request.headers.get("authorization", "")},
                lambda status, headers: statuses.append(status))
            return httpx.Response(int(statuses[0].split()[0]), content=b"".join(value))

        sender = RelaySender(RelayConfig("https://relay.example", identity, source_key),
                             httpx.Client(transport=httpx.MockTransport(respond)))
        self.addCleanup(sender.close)
        self.assertTrue(sender.sync_clients(store, 100))
        self.assertEqual(self.call("/v1/destinations", "PUT", {"sourceID": identity,
            "clientID": paired["clientID"], "mode": "alert", "deviceToken": self.token,
            "environment": "production"}, paired["credential"])[0], 200)
        payload, headers = notification(identity, str(uuid.uuid4()),
                                        {"seq": 7, "state": "finished", "at": 100}, 100)
        result = sender.send({"client_id": paired["clientID"], "token": self.token,
                              "environment": "production"}, payload, headers, 100)
        self.assertEqual(result.status, 200)
        store.revoke(paired["clientID"])
        self.assertTrue(sender.sync_clients(store, 101))
        self.assertEqual(sender.send({"client_id": paired["clientID"], "token": self.token,
                                      "environment": "production"}, payload, headers, 101).status, 0)

    def test_mac_install_generates_source_credential_without_apns_key(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / "installed"
        (root / "lib/service").mkdir(parents=True)
        (root / "lib/service/push.py").touch()
        source_id = Store(root / "data/hub.sqlite3").metadata("source_id")
        private = root / "private"
        private.mkdir()
        key = private / "apns-key.p8"
        key.write_text("legacy")
        plist = Path(temporary.name) / "source.plist"
        plist.write_bytes(plistlib.dumps({"ProgramArguments": ["/tmp/PacemanBackground"]}))
        venv = root / "push-venv"
        (venv / "bin").mkdir(parents=True)
        (venv / "bin/python3").touch()
        with (patch.multiple(mac_push, ROOT=root, PRIVATE=private, KEY=key,
                             WATCH_KEY=private / "watch-key.p8", CONFIG=private / "apns.json",
                             VENV=venv, SOURCE_PLIST=plist, PLIST=Path(temporary.name) / "absent.plist"),
              patch.object(mac_push.subprocess, "run")):
            mac_push.install(relay_url="https://relay.example")
        value = json.loads((private / "apns.json").read_text())
        self.assertEqual(value["sourceID"], source_id)
        self.assertEqual(value["relayURL"], "https://relay.example")
        self.assertNotIn("keyPath", value)
        self.assertFalse(key.exists())
        self.assertEqual(private.stat().st_mode & 0o777, 0o700)
        self.assertEqual((private / "apns.json").stat().st_mode & 0o777, 0o600)

    def test_mac_uninstall_revokes_source_before_discarding_credential(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        config = Path(temporary.name) / "relay.json"
        config.write_text(json.dumps({"relayURL": "https://relay.example", "sourceID": self.source,
                                      "credential": self.source_key}))
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): pass
        class Opener:
            def open(self, request, timeout):
                self.assert_request(request, timeout)
                return Response()
            def assert_request(self, request, timeout):
                assert request.full_url == "https://relay.example/v1/sources"
                assert request.get_method() == "DELETE"
                assert timeout == 5
        with patch.object(mac_uninstall, "build_opener", return_value=Opener()):
            self.assertIsNone(mac_uninstall.revoke_relay_source(config))


if __name__ == "__main__":
    unittest.main()
