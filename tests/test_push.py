import json
from pathlib import Path
import tempfile
import unittest

from service.hub import Store
from service.push import APNs, Config, Result, Worker, notification


class FakeSender:
    def __init__(self):
        self.calls = []
        self.result = Result(200, "Accepted", "test-apns-id")

    def send(self, device, payload, headers, now):
        self.calls.append((device, payload, headers, now))
        return self.result


class PushWorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(Path(self.tmp.name) / "hub.sqlite3")
        self.client = self.pair()
        self.device_token = "ab" * 32
        self.register()
        self.sender = FakeSender()
        self.log = Path(self.tmp.name) / "push.jsonl"
        self.worker = Worker(self.store, self.sender, self.log)

    def pair(self):
        return self.store.redeem(self.store.invite("https://source.example")["invitation"])

    def register(self, mode="alert"):
        return self.store.push_device(self.client["credential"], {
            "deviceToken": self.device_token, "environment": "development", "mode": mode})

    def emit(self, state, at=100):
        revision = self.store.emit(state)
        with self.store.connect() as db:
            db.execute("UPDATE events SET at=? WHERE seq=?", (at, revision))
        return revision

    def test_registration_is_scoped_and_revocation_removes_destination(self):
        other = self.pair()
        self.assertEqual(self.store.push_device(other["credential"]), {"registered": False})
        self.assertIsNone(self.store.push_device("incorrect"))
        self.store.push_device(other["credential"], remove=True)
        self.assertTrue(self.store.push_device(self.client["credential"])["registered"])
        self.store.revoke(self.client["clientID"])
        self.emit("needs_input")
        self.worker.step(100)
        self.assertFalse(self.sender.calls)

    def test_registration_does_not_replay_existing_events(self):
        self.worker.step(100)
        self.assertFalse(self.sender.calls)
        self.emit("needs_input")
        self.register()  # Re-registering an unchanged destination must not skip an unsent event.
        self.worker.step(100)
        self.assertEqual(len(self.sender.calls), 1)
        Worker(Store(self.store.path), self.sender, self.log).step(200)
        self.assertEqual(len(self.sender.calls), 1)

    def test_alert_has_hint_and_background_wake_request_but_no_private_content(self):
        revision = self.emit("needs_input")
        self.worker.step(100)
        _, payload, headers, _ = self.sender.calls[0]
        self.assertEqual(payload["aps"]["content-available"], 1)
        self.assertEqual(payload["companion"]["revision"], revision)
        self.assertEqual(headers["apns-push-type"], "alert")
        self.assertEqual(headers["apns-priority"], "10")
        self.assertEqual(headers["apns-expiration"], "400")
        self.assertLess(len(json.dumps(payload)), 4096)
        for secret in (self.client["credential"], self.device_token, "https://source.example"):
            self.assertNotIn(secret, json.dumps(payload))
            self.assertNotIn(secret, self.log.read_text())
        self.assertIn('"stage":"apns_accepted"', self.log.read_text())

    def test_only_latest_state_is_sent_without_replaying_attention_events(self):
        self.emit("needs_input")
        self.emit("working")
        self.worker.step(100)
        self.assertEqual(len(self.sender.calls), 1)
        self.assertEqual(self.sender.calls[0][1]["aps"]["alert"]["title"], "Agent working")
        self.emit("needs_input")
        newest = self.emit("finished")
        self.worker.step(110)
        self.assertEqual(len(self.sender.calls), 2)
        self.assertEqual(self.sender.calls[-1][1]["companion"]["revision"], newest)

    def test_retry_is_persistent_bounded_and_coalesces_to_latest_event(self):
        self.emit("needs_input")
        self.sender.result = Result(503, "ServiceUnavailable", "retry-id")
        self.worker.step(100)
        self.worker.step(101)
        self.assertEqual(len(self.sender.calls), 1)
        newest = self.emit("finished", 109)
        self.sender.result = Result(200, "Accepted", "accepted-id")
        Worker(Store(self.store.path), self.sender, self.log).step(111)
        self.assertEqual(len(self.sender.calls), 2)
        self.assertEqual(self.sender.calls[-1][1]["companion"]["revision"], newest)

    def test_progress_is_passive_and_attention_alerts_keep_their_sound(self):
        worker = Worker(self.store, self.sender, self.log)
        self.emit("working", 100)
        worker.step(100)
        _, payload, headers, _ = self.sender.calls[0]
        self.assertEqual(payload["aps"]["interruption-level"], "passive")
        self.assertNotIn("sound", payload["aps"])
        self.assertEqual(payload["aps"]["content-available"], 1)
        self.assertEqual(payload["aps"]["alert"]["title"], "Agent working")
        self.assertEqual(headers["apns-push-type"], "alert")
        self.assertEqual(headers["apns-priority"], "10")
        self.assertEqual(json.loads(self.log.read_text().splitlines()[0])["presentation"], "passive")
        # The normal attempt spacing still applies. Only the newest state survives.
        self.emit("working", 101)
        worker.step(101)
        self.assertEqual(len(self.sender.calls), 1)
        newest = self.emit("needs_input", 102)
        worker.step(110)
        payload = self.sender.calls[-1][1]
        self.assertEqual(payload["companion"]["revision"], newest)
        self.assertEqual(payload["aps"]["sound"], "default")
        self.assertNotIn("interruption-level", payload["aps"])
        self.assertEqual(payload["aps"]["alert"]["title"], "Agent needs input")
        self.emit("finished", 120)
        worker.step(120)
        self.assertEqual(self.sender.calls[-1][1]["aps"]["alert"]["title"], "Agent finished")
        self.emit("idle", 130)
        worker.step(130)
        self.assertEqual(len(self.sender.calls), 4)
        aps = self.sender.calls[-1][1]["aps"]
        self.assertEqual(aps["alert"]["title"], "No active sessions")
        self.assertEqual(aps["interruption-level"], "passive")
        self.assertNotIn("sound", aps)

    def test_notification_policy_preserves_silent_registration_and_limit(self):
        self.register("background")
        worker = Worker(self.store, self.sender, self.log)
        self.emit("working", 100)
        worker.step(100)
        _, payload, headers, _ = self.sender.calls[0]
        self.assertEqual(payload["aps"], {"content-available": 1})
        self.assertEqual(headers["apns-push-type"], "background")
        self.emit("working", 110)
        worker.step(110)
        self.assertEqual(len(self.sender.calls), 1)

    def test_expired_progress_is_dropped(self):
        self.emit("working", 100)
        Worker(self.store, self.sender, self.log).step(401)
        self.assertFalse(self.sender.calls)

    def test_expired_events_are_dropped_without_sending(self):
        self.emit("needs_input", 100)
        self.worker.step(401)
        self.assertFalse(self.sender.calls)

    def test_invalid_destination_is_removed(self):
        self.emit("needs_input")
        self.sender.result = Result(410, "Unregistered", "invalid-id")
        self.worker.step(100)
        self.assertEqual(self.store.push_device(self.client["credential"]), {"registered": False})

    def test_background_only_has_no_alert_and_limits_attempt_frequency(self):
        self.register("background")
        self.emit("working", 100)
        self.worker.step(100)
        _, payload, headers, _ = self.sender.calls[0]
        self.assertEqual(payload["aps"], {"content-available": 1})
        self.assertEqual(headers["apns-push-type"], "background")
        self.assertEqual(headers["apns-priority"], "5")
        self.emit("finished", 1000)
        self.worker.step(1200)
        self.assertEqual(len(self.sender.calls), 1)
        self.emit("needs_input", 1301)
        self.worker.step(1301)
        self.assertEqual(len(self.sender.calls), 2)

    def test_destination_token_rotation_preserves_new_destination_on_old_failure(self):
        self.emit("needs_input")
        original = self.sender.send
        def rotate(device, payload, headers, now):
            self.device_token = "cd" * 32
            self.register()
            original(device, payload, headers, now)
            return Result(410, "Unregistered", "old-token")
        self.sender.send = rotate
        self.worker.step(100)
        self.assertTrue(self.store.push_device(self.client["credential"])["registered"])


class APNsProtocolTests(unittest.TestCase):
    def setUp(self):
        try:
            import httpx
            import jwt
            from cryptography.hazmat.primitives.asymmetric import ec
            from cryptography.hazmat.primitives import serialization
        except ImportError:
            self.skipTest("Install requirements-push.txt to exercise real JWT/HTTP client code")
        self.httpx, self.jwt = httpx, jwt
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.pem = self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption())
        self.config = Config("ABCDEFGHIJ", "1234567890", "com.example.companion", "development", self.pem)

    def test_http_request_and_jwt_signature_then_refresh(self):
        calls = []
        def handle(request):
            calls.append(request)
            return self.httpx.Response(200)
        sender = APNs(self.config, self.httpx.Client(transport=self.httpx.MockTransport(handle)))
        self.addCleanup(sender.close)
        payload, headers = notification("source", "generation", {"seq": 1, "state": "finished", "at": 100}, "alert", 100)
        device = {"token": "ab" * 32, "environment": "development"}
        self.assertEqual(sender.send(device, payload, headers, 100).status, 200)
        request = calls[0]
        self.assertEqual(str(request.url), "https://api.sandbox.push.apple.com/3/device/" + device["token"])
        self.assertEqual(request.headers["apns-topic"], self.config.topic)
        first_jwt = request.headers["authorization"].removeprefix("bearer ")
        claims = self.jwt.decode(first_jwt, self.key.public_key(), algorithms=["ES256"])
        self.assertEqual(claims, {"iss": self.config.team_id, "iat": 100})
        self.assertEqual(self.jwt.get_unverified_header(first_jwt)["kid"], self.config.key_id)
        sender.send(device, payload, headers, 200)
        self.assertEqual(request.headers["authorization"], calls[-1].headers["authorization"])
        sender.send(device, payload, headers, 3200)
        self.assertNotEqual(request.headers["authorization"], calls[-1].headers["authorization"])

    def test_environment_mismatch_never_contacts_apple(self):
        def forbidden(_):
            self.fail("Must not send a production token to sandbox")
        sender = APNs(self.config, self.httpx.Client(transport=self.httpx.MockTransport(forbidden)))
        self.addCleanup(sender.close)
        result = sender.send({"token": "ab" * 32, "environment": "production"}, {}, {}, 100)
        self.assertEqual(result.reason, "EnvironmentMismatch")

    def test_apns_failure_and_network_error_are_sanitized(self):
        def rejected(_): return self.httpx.Response(400, json={"reason": "BadDeviceToken"})
        sender = APNs(self.config, self.httpx.Client(transport=self.httpx.MockTransport(rejected)))
        self.addCleanup(sender.close)
        result = sender.send({"token": "ab" * 32, "environment": "development"}, {}, {"apns-id": "id"}, 100)
        self.assertEqual(result.reason, "BadDeviceToken")
        def unavailable(request): raise self.httpx.ConnectError("secret request URL", request=request)
        sender.client.close()
        sender.client = self.httpx.Client(transport=self.httpx.MockTransport(unavailable))
        result = sender.send({"token": "ab" * 32, "environment": "development"}, {}, {"apns-id": "id"}, 101)
        self.assertEqual(result, Result(0, "TransportError", "id"))
