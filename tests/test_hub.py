import concurrent.futures
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest

from tests.identity import device
from service.hub import Server, Store, endpoint


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(Path(self.temp.name) / "hub.sqlite3")

    def test_single_use_even_when_redeemed_concurrently(self):
        invitation = self.store.invite("https://test.example", now=10)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.store.redeem(invitation["invitation"], now=11, device=device()), range(8)))
        self.assertEqual(sum(result is not None for result in results), 1)

    def test_expiry_boundary_and_unknown_invitation(self):
        invitation = self.store.invite("https://test.example", now=10)
        self.assertIsNone(self.store.redeem(invitation["invitation"], now=310, device=device()))
        self.assertIsNone(self.store.redeem("unknown", device=device()))

    def test_revoke_and_private_storage(self):
        invitation = self.store.invite("https://test.example")
        client = self.store.redeem(invitation["invitation"], device=device())
        self.assertTrue(self.store.authorized(client["credential"]))
        self.assertFalse(self.store.authorized(""))
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        with self.store.connect() as db:
            row = db.execute("SELECT hash FROM clients").fetchone()
            self.assertNotEqual(row[0], client["credential"])
        self.assertTrue(self.store.revoke(client["clientID"]))
        self.assertFalse(self.store.authorized(client["credential"]))

    def test_revision_and_source_identity_survive_restart(self):
        first = self.store.snapshot()
        self.store.emit("working")
        second = Store(self.store.path).snapshot()
        self.assertEqual(first["sourceID"], second["sourceID"])
        self.assertEqual(first["generation"], second["generation"])
        self.assertGreater(second["revision"], first["revision"])
        self.assertEqual(second["state"], "working")
        self.assertEqual(second["mode"], "synthetic")

    def test_snapshot_read_does_not_change_event_or_acknowledge_it(self):
        self.store.emit("needs_input")
        a, b = self.store.snapshot(), self.store.snapshot()
        self.assertEqual(a["revision"], b["revision"])
        self.assertEqual(a["changedAt"], b["changedAt"])
        self.assertEqual(a["state"], "needs_input")

    def test_scheduler_executes_once_in_order(self):
        with self.store.connect() as db:
            db.executemany("INSERT INTO schedule(due,state) VALUES (?,?)", [(10, "working"), (11, "finished")])
        self.store.tick(now=11)
        self.store.tick(now=12)
        with self.store.connect() as db:
            rows = db.execute("SELECT state FROM events ORDER BY seq").fetchall()
        self.assertEqual([row[0] for row in rows], ["idle", "working", "finished"])

    def test_endpoint_rejects_plaintext_and_credentials(self):
        for value in ["http://test", "https://user:pass@test", "https://test/path", "https://test?secret=x", "https://test#x"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                endpoint(value)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "hub.sqlite3")
        self.server = Server(("127.0.0.1", 0), self.store)
        self.worker = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        self.worker.start()
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=2)
        self.temp.cleanup()

    def request(self, method, path, body=None, token=None):
        client = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        headers = {} if token is None else {"Authorization": "Bearer " + token}
        encoded = json.dumps(body) if body is not None else None
        client.request(method, path, encoded, headers)
        response = client.getresponse()
        status, data = response.status, json.loads(response.read())
        client.close()
        return status, data

    def paired(self):
        invitation = self.store.invite("https://test.example")
        status, client = self.request("POST", "/v1/pair", {"invitation": invitation["invitation"], "device": device()})
        self.assertEqual(status, 200)
        return client

    def test_notification_registration_survives_worker_restart(self):
        from service.push import Worker
        from tests.test_push import FakeSender
        pair = self.paired()
        sender = FakeSender()
        now = time.time()
        for offset in range(4):
            status, ack = self.request("POST", "/v1/push", {
                "deviceToken": "ab" * 32, "environment": "development",
                "mode": "alert"}, pair["credential"])
            self.assertEqual(status, 200)
            self.assertTrue(ack["registered"])
            self.assertTrue(self.request("GET", "/v1/push", token=pair["credential"])[1]["registered"])
            self.store.emit("finished")
            # Reload the database as a separately running/restarted worker would.
            Worker(Store(self.store.path), sender, Path(self.temp.name) / "push.jsonl").step(now + offset * 11)
            self.assertEqual(len(sender.calls), offset + 1)
            aps = sender.calls[-1][1]["aps"]
            self.assertEqual(aps.get("interruption-level", "active"), "active")
            self.assertIn("sound", aps)
            self.assertNotIn("content-available", aps)

    def test_pair_snapshot_revocation_and_no_control_endpoint(self):
        self.assertEqual(self.request("GET", "/v1/snapshot")[0], 401)
        client = self.paired()
        status, value = self.request("GET", "/v1/snapshot", token=client["credential"])
        self.assertEqual(status, 200)
        self.assertEqual(value["sourceID"], client["sourceID"])
        self.assertEqual(self.request("POST", "/v1/emit", {"state": "working"}, client["credential"])[0], 404)
        self.store.revoke(client["clientID"])
        self.assertEqual(self.request("GET", "/v1/snapshot", token=client["credential"])[0], 401)

    def test_invalid_json_shape_is_rejected(self):
        for body in [[], None, {"invitation": 123}, {"invitation": "x"}]:
            self.assertEqual(self.request("POST", "/v1/pair", body)[0], 400)

    def test_retired_stream_endpoint_is_not_served(self):
        pair = self.paired()
        self.assertEqual(self.request("GET", "/v1/events", token=pair["credential"])[0], 404)

    def test_schedule_fires_without_snapshot_requests(self):
        with self.store.connect() as db:
            db.execute("INSERT INTO schedule(due,state) VALUES (?,?)", (time.time(), "finished"))
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            with self.store.connect() as db:
                state = db.execute("SELECT state FROM events ORDER BY seq DESC LIMIT 1").fetchone()[0]
            if state == "finished": break
            time.sleep(0.02)
        self.assertEqual(state, "finished")

    def test_pairing_rate_limit(self):
        for _ in range(20):
            self.request("POST", "/v1/pair", {"invitation": "x" * 43})
        self.assertEqual(self.request("POST", "/v1/pair", {"invitation": "x" * 43})[0], 429)

    def test_push_registration_requires_pairing_and_can_only_remove_own_destination(self):
        payload = {"deviceToken": "ab" * 32, "environment": "development", "mode": "alert"}
        self.assertEqual(self.request("POST", "/v1/push", payload)[0], 401)
        first, second = self.paired(), self.paired()
        status, value = self.request("POST", "/v1/push", payload, first["credential"])
        self.assertEqual(status, 200)
        self.assertTrue(value["registered"])
        self.assertNotIn("deviceToken", value)
        self.assertEqual(self.request("GET", "/v1/push", token=second["credential"])[1], {"registered": False})
        self.request("DELETE", "/v1/push", token=second["credential"])
        self.assertTrue(self.request("GET", "/v1/push", token=first["credential"])[1]["registered"])
        self.assertEqual(self.request("DELETE", "/v1/push", token=first["credential"])[1], {"registered": False})

    def test_invalid_push_registration_and_revoked_client(self):
        pair = self.paired()
        for payload in [[], {}, {"deviceToken": "https://attacker.example", "environment": "development", "mode": "alert"},
                        {"deviceToken": "ab" * 32, "environment": "other", "mode": "alert"},
                        {"deviceToken": "ab" * 32, "environment": "development", "mode": "voip"}]:
            self.assertEqual(self.request("POST", "/v1/push", payload, pair["credential"])[0], 400)
        self.store.revoke(pair["clientID"])
        self.assertEqual(self.request("GET", "/v1/push", token=pair["credential"])[0], 401)

    def test_push_registration_rejects_invalid_display_names(self):
        pair = self.paired()
        base = {"deviceToken": "ab" * 32, "environment": "development", "mode": "alert"}
        for name in (" ", " bad", "bad\nname", "x" * 1025, 7):
            self.assertEqual(self.request("POST", "/v1/push", {**base, "displayName": name},
                                          pair["credential"])[0], 400)
        self.assertEqual(self.request("POST", "/v1/push", {**base, "displayName": "Desk"},
                                      pair["credential"])[0], 200)
        self.assertEqual(self.request("POST", "/v1/push", {**base, "displayName": "Café 🧑‍💻"},
                                      pair["credential"])[0], 200)


if __name__ == "__main__":
    unittest.main()
