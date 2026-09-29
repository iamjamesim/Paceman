import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import uuid

from service.hub import Store
from service.push import RelayConfig, RelaySender, Result, Worker, live_notification, live_start_notification, notification, watch_allowance_notification
from service.relay import RelayApp, enroll, revoke
from tests.identity import device
import macos.install_push as mac_push


class FakeAPNs:
    def __init__(self):
        self.calls = []

    def send(self, device, payload, headers, now):
        self.calls.append((device, payload, headers))
        return Result(200, "Accepted", headers["apns-id"])


class RelayTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "sources.json"
        self.source = str(uuid.uuid4())
        self.other = str(uuid.uuid4())
        self.credential = enroll(self.path, self.source)
        self.other_credential = enroll(self.path, self.other)
        self.sender = FakeAPNs()
        self.app = RelayApp(self.sender, self.path, now=lambda: 100)
        self.payload, self.headers = notification(self.source, str(uuid.uuid4()),
            {"seq": 7, "state": "finished", "at": 100}, 100)
        self.request = {"sourceID": self.source, "deviceToken": "ab" * 32,
                        "environment": "development", "mode": "alert",
                        "payload": self.payload, "headers": self.headers}

    def call(self, value=None, credential=None):
        body = json.dumps(self.request if value is None else value).encode()
        status = []
        response = self.app({"PATH_INFO": "/v1/send", "REQUEST_METHOD": "POST",
                             "CONTENT_LENGTH": str(len(body)), "wsgi.input": io.BytesIO(body),
                             "HTTP_AUTHORIZATION": "Bearer " + (credential or self.credential)},
                            lambda result, headers: status.append(result))
        return int(status[0].split()[0]), json.loads(b"".join(response))

    def test_authenticated_delivery_and_private_registry(self):
        status, response = self.call()
        self.assertEqual(status, 200)
        self.assertEqual(response, {"status": 200, "reason": "Accepted", "apnsID": self.headers["apns-id"]})
        self.assertEqual(self.sender.calls[0][0]["token"], "ab" * 32)
        self.assertNotIn(self.credential, self.path.read_text())
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_other_source_cannot_send_or_replay_this_source(self):
        self.assertEqual(self.call(credential=self.other_credential)[0], 401)
        self.assertEqual(self.call({**self.request, "sourceID": self.other}, self.other_credential)[0], 400)
        self.assertEqual(self.sender.calls, [])

    def test_revocation_takes_effect_without_restart(self):
        self.assertEqual(self.call()[0], 200)
        revoke(self.path, self.source)
        self.assertEqual(self.call()[0], 401)
        self.assertEqual(len(self.sender.calls), 1)
        self.assertEqual(self.call({**self.request, "sourceID": self.other}, self.other_credential)[0], 400)

    def test_rejects_extra_data_and_unsafe_apns_headers(self):
        for changed in (
            {**self.request, "payload": {**self.payload, "transcript": "private"}},
            {**self.request, "payload": {**self.payload, "companion": {**self.payload["companion"],
                                                                          "sourceURL": "https://example.com"}}},
            {**self.request, "headers": {**self.headers, "apns-topic": "other.app"}},
            {**self.request, "headers": {**self.headers, "apns-expiration": "100000"}},
        ):
            self.assertEqual(self.call(changed)[0], 400)
        self.assertEqual(self.sender.calls, [])

    def test_existing_live_start_and_watch_payloads_are_accepted(self):
        snapshot = {"sourceID": self.source, "sourceName": "Studio Mac", "generation": str(uuid.uuid4()),
                    "revision": 7, "state": "working", "observedAt": 100, "changedAt": 100,
                    "sessions": [{"state": "working", "provider": "codex"}]}
        live, headers = live_start_notification(snapshot, 100)
        self.assertEqual(self.call({**self.request, "mode": "liveactivity", "payload": live,
                                    "headers": headers})[0], 200)
        watch, headers = watch_allowance_notification(self.source, {"provider": "codex", "remaining": 42,
            "window": 2, "windowDurationMins": 300, "updatedAt": 100, "resetsAt": 3600}, 100)
        self.assertEqual(self.call({**self.request, "mode": "watch", "payload": watch,
                                    "headers": headers})[0], 200)
        for ending in (False, True):
            update, headers = live_notification(snapshot, 100, ending=ending)
            self.assertEqual(self.call({**self.request, "mode": "liveactivity", "payload": update,
                                        "headers": headers})[0], 200)
        self.assertEqual(len(self.sender.calls), 4)

    def test_unicode_phone_name_is_allowed_without_extra_fields(self):
        payload, headers = notification(self.source, str(uuid.uuid4()),
            {"seq": 8, "state": "working", "at": 100}, 100, phone_name="Café 🧑‍💻")
        self.assertEqual(self.call({**self.request, "payload": payload, "headers": headers})[0], 200)

    def test_source_worker_keeps_per_client_registration_and_revocation(self):
        try:
            import httpx
        except ImportError:
            self.skipTest("Install requirements-push.txt")
        store = Store(self.path.parent / "hub.sqlite3")
        source = store.metadata("source_id")
        credential = enroll(self.path, source)
        first = store.redeem(store.invite("https://source.example")["invitation"], device=device())
        second = store.redeem(store.invite("https://source.example")["invitation"], device=device())
        store.push_device(first["credential"], {"deviceToken": "ab" * 32, "environment": "development"})
        store.push_device(second["credential"], {"deviceToken": "cd" * 32, "environment": "development"})
        store.revoke(first["clientID"])
        def transport(request):
            body = request.content
            status = []
            response = self.app({"PATH_INFO": request.url.path, "REQUEST_METHOD": request.method,
                "CONTENT_LENGTH": str(len(body)), "wsgi.input": io.BytesIO(body),
                "HTTP_AUTHORIZATION": request.headers["authorization"]},
                lambda code, headers: status.append(code))
            return httpx.Response(int(status[0].split()[0]), content=b"".join(response))
        sender = RelaySender(RelayConfig("https://push.example.com", source, credential),
                             httpx.Client(transport=httpx.MockTransport(transport)))
        self.addCleanup(sender.close)
        revision = store.emit("finished")
        with store.connect() as db:
            db.execute("UPDATE events SET at=? WHERE seq=?", (100, revision))
        Worker(store, sender, self.path.parent / "delivery.jsonl").step(100)
        self.assertEqual([call[0]["token"] for call in self.sender.calls], ["cd" * 32])
        self.assertNotIn("ab" * 32, (self.path.parent / "delivery.jsonl").read_text())

    def test_relay_config_requires_https_and_source_credential(self):
        value = {"relayURL": "https://push.example.com", "sourceID": self.source,
                 "credential": self.credential}
        config = RelayConfig.load(value)
        self.assertEqual(config.source_id, self.source)
        for bad in ({**value, "relayURL": "http://push.example.com"},
                    {**value, "relayURL": "https://user@push.example.com"},
                    {**value, "keyPath": "secret.p8"}):
            with self.assertRaises(ValueError):
                RelayConfig.load(bad)

    def test_source_sender_returns_apns_result_and_sanitizes_relay_failures(self):
        try:
            import httpx
        except ImportError:
            self.skipTest("Install requirements-push.txt")
        requests = []
        def respond(request):
            requests.append(request)
            return httpx.Response(200, json={"status": 200, "reason": "Accepted", "apnsID": self.headers["apns-id"]})
        config = RelayConfig.load({"relayURL": "https://push.example.com", "sourceID": self.source,
                                   "credential": self.credential})
        sender = RelaySender(config, httpx.Client(transport=httpx.MockTransport(respond)))
        self.addCleanup(sender.close)
        result = sender.send({"token": "ab" * 32, "environment": "development"},
                             self.payload, self.headers, 100)
        self.assertEqual(result.status, 200)
        self.assertEqual(requests[0].headers["authorization"], "Bearer " + self.credential)
        self.assertEqual(requests[0].url.path, "/v1/send")
        sender.client.close()
        sender.client = httpx.Client(transport=httpx.MockTransport(lambda _: httpx.Response(401)))
        self.assertEqual(sender.send({"token": "ab" * 32, "environment": "development"},
                                     self.payload, self.headers, 100).reason, "RelayRejected")

    def test_mac_relay_install_keeps_only_source_credential(self):
        root = self.path.parent / "installed"
        (root / "lib/service").mkdir(parents=True)
        (root / "lib/service/push.py").touch()
        store = Store(root / "data/hub.sqlite3")
        private = root / "private"
        private.mkdir()
        old_key = private / "apns-key.p8"
        old_watch_key = private / "apns-watch-key.p8"
        old_key.write_text("old key")
        old_watch_key.write_text("old watch key")
        config_path = self.path.parent / "relay.json"
        config_path.write_text(json.dumps({"relayURL": "https://push.example.com",
            "sourceID": store.metadata("source_id"), "credential": self.credential}))
        plist = self.path.parent / "source.plist"
        plist.write_bytes(plistlib.dumps({"ProgramArguments": ["/tmp/PacemanBackground"]}))
        venv = root / "push-venv"
        (venv / "bin").mkdir(parents=True)
        (venv / "bin/python3").touch()
        with (patch.multiple(mac_push, ROOT=root, PRIVATE=private, KEY=old_key,
                             WATCH_KEY=old_watch_key, CONFIG=private / "apns.json", VENV=venv,
                             SOURCE_PLIST=plist, PLIST=self.path.parent / "absent.plist"),
              patch.object(mac_push.subprocess, "run")):
            mac_push.install(config_path)
        self.assertFalse(old_key.exists())
        self.assertFalse(old_watch_key.exists())
        self.assertEqual(json.loads((private / "apns.json").read_text())["sourceID"], store.metadata("source_id"))
        self.assertEqual((private / "apns.json").stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
