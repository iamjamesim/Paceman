from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from tests.identity import device
from service.hub import Store
from service.push import APNs, Config, Result, Worker, notification, watch_allowance_notification
from service.relay import APNsRouter, valid_payload


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
        return self.store.redeem(self.store.invite("https://source.example")["invitation"], device=device())

    def test_watch_provider_selection_survives_newer_other_provider_readings(self):
        now=1800000000
        def reading(provider,left):
            return dict(provider=provider,remaining=left,window=1,windowDurationMins=10080,
                        updatedAt=now,resetsAt=now+86400)
        source=dict(sourceID=self.store.metadata("source_id"),allowance=reading("codex",3),
                    allowances=[reading("codex",3),reading("claude",80)])
        payload={"deviceToken":"ef"*32,"environment":"development","provider":"claude","selectionRevision":2}
        self.store.watch_push_device(self.client["credential"],payload)
        self.worker.step_watch_allowance(now,source)
        self.assertEqual(self.sender.calls[-1][1]["allowance"]["provider"],"claude")
        self.assertEqual(self.sender.calls[-1][1]["selectionRevision"],2)
        self.assertEqual(self.sender.calls[-1][1]["sourceID"],source["sourceID"])
        # A late registration cannot undo the user's newer choice.
        self.assertEqual(self.store.watch_push_device(self.client["credential"],{**payload,"provider":"codex","selectionRevision":1}),{"registered":False})
        source["allowances"]=[reading("codex",1)]
        self.worker.step_watch_allowance(now+2000,source)
        self.assertEqual(len(self.sender.calls),1)
        self.store.watch_push_device(self.client["credential"],{**payload,"provider":"codex","selectionRevision":3})
        self.worker.step_watch_allowance(now,source)
        self.assertEqual(self.sender.calls[-1][1]["allowance"]["provider"],"codex")

    def test_complete_watch_usage_preserves_legacy_delivery_and_clears_signed_out_provider(self):
        now = 1800000000
        def reading(provider, window, left):
            return dict(provider=provider, remaining=left, window=window,
                        windowDurationMins=10080 if window == 1 else 300,
                        updatedAt=now, resetsAt=now+86400)
        values = [reading(p, w, left) for p, left in (("codex", 70), ("claude", 20)) for w in (1, 2)]
        source = dict(sourceID=self.store.metadata("source_id"), observedAt=now+0.5, allowances=values)
        modern = {"deviceToken": "ef"*32, "environment": "development", "provider": "claude",
                  "selectionRevision": 2, "usageSchema": 2}
        self.store.watch_push_device(self.client["credential"], modern)
        other = self.pair()
        self.store.watch_push_device(other["credential"], {"deviceToken": "cd"*32, "environment": "development"})
        self.worker.step_watch_allowance(now, source)
        by_token = {call[0]["token"]: call[1] for call in self.sender.calls}
        self.assertEqual(by_token[modern["deviceToken"]]["schema"], 2)
        self.assertEqual(by_token[modern["deviceToken"]]["observedAt"], now+0.5)
        self.assertCountEqual(by_token[modern["deviceToken"]]["allowances"], values)
        self.assertEqual(by_token["cd"*32]["schema"], 1)
        self.assertEqual(by_token["cd"*32]["allowance"]["provider"], "codex")
        for payload in by_token.values():
            self.assertTrue(valid_payload("watch", source["sourceID"], payload))
        self.worker.step_watch_allowance(now+1199, source)
        self.assertEqual(len(self.sender.calls), 2)
        source["allowances"] = [v for v in values if v["provider"] == "codex"]
        self.worker.step_watch_allowance(now+1200, source)
        self.assertEqual(self.sender.calls[-1][1]["allowances"], source["allowances"])
        source["allowances"] = []
        self.worker.step_watch_allowance(now+2400, source)
        self.assertEqual(self.sender.calls[-1][1]["allowances"], [])
        count = len(self.sender.calls)
        self.worker.step_watch_allowance(now+10000, source)
        self.assertEqual(len(self.sender.calls), count)  # No recovery churn for empty/stale data.

    def test_complete_watch_payload_rejects_unbounded_duplicate_and_future_data(self):
        now = 1800000000
        source = self.store.metadata("source_id")
        reading = dict(provider="claude", remaining=20, window=2, windowDurationMins=300,
                       updatedAt=now, resetsAt=now+3600)
        payload = {"aps": {"content-available": 1}, "schema": 2, "sourceID": source,
                   "selectionRevision": 2, "observedAt": now, "allowances": [reading]}
        self.assertTrue(valid_payload("watch", source, payload))
        self.assertTrue(valid_payload("watch", source, {**payload, "allowances": []}))
        for bad in ({**payload, "allowances": [reading]*5},
                    {**payload, "allowances": [reading, {**reading, "windowDurationMins": 60}]},
                    {**payload, "allowances": [{**reading, "updatedAt": now+1}]},
                    {**payload, "allowances": [{**reading, "prompt": "private"}]},
                    {**payload, "sourceID": "bbbbbbbb-2222-4333-8444-555555555555"},
                    {**payload, "observedAt": True}, {**payload, "observedAt": float("nan")},
                    {**payload, "allowance": reading}):
            with self.subTest(payload=bad):
                self.assertFalse(valid_payload("watch", source, bad))

    def test_watch_capability_upgrade_resets_delivery_without_losing_registration(self):
        payload = {"deviceToken": "ef"*32, "environment": "development", "selectionRevision": 2}
        self.store.watch_push_device(self.client["credential"], payload)
        with self.store.connect() as db:
            db.execute("UPDATE watch_push_devices SET last_fingerprint='legacy',next_attempt=1800000000")
        self.store.watch_push_device(self.client["credential"], {**payload, "usageSchema": 2})
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM watch_push_devices").fetchone()
        self.assertEqual(row["usage_schema"], 2)
        self.assertEqual(row["next_attempt"], 0)
        self.assertIsNone(row["last_fingerprint"])
        with self.assertRaises(ValueError):
            self.store.watch_push_device(self.client["credential"], {**payload, "usageSchema": True})
        with self.store.connect() as db:
            db.execute("ALTER TABLE watch_push_devices DROP COLUMN usage_schema")
        reopened = Store(self.store.path)
        with reopened.connect() as db:
            row = db.execute("SELECT usage_schema,token FROM watch_push_devices").fetchone()
        self.assertEqual((row["usage_schema"], row["token"]), (1, payload["deviceToken"]))

    def test_existing_source_database_adds_per_phone_name(self):
        old = Path(self.tmp.name) / "old.sqlite3"
        with closing(sqlite3.connect(old)) as db, db:
            db.execute("CREATE TABLE clients(id TEXT PRIMARY KEY, hash TEXT UNIQUE NOT NULL, "
                       "created REAL NOT NULL, last_seen REAL NOT NULL DEFAULT 0)")
        Store(old)
        with closing(sqlite3.connect(old)) as db, db:
            columns = {row[1] for row in db.execute("PRAGMA table_info(clients)")}
        self.assertIn("display_name", columns)

    def test_existing_push_registration_survives_mode_column_removal(self):
        with self.store.connect() as db:
            db.execute("ALTER TABLE push_devices ADD COLUMN mode TEXT NOT NULL DEFAULT 'alert'")
        reopened = Store(self.store.path)
        with reopened.connect() as db:
            columns = {row[1] for row in db.execute("PRAGMA table_info(push_devices)")}
        self.assertNotIn("mode", columns)
        self.assertTrue(reopened.push_device(self.client["credential"])["registered"])

    def test_existing_watch_registration_adds_recovery_counter(self):
        self.store.watch_push_device(self.client["credential"], {
            "deviceToken": "ef" * 32, "environment": "development"})
        with self.store.connect() as db:
            db.execute("ALTER TABLE watch_push_devices DROP COLUMN recovery_sends")
        reopened = Store(self.store.path)
        with reopened.connect() as db:
            row = db.execute("SELECT token,recovery_sends FROM watch_push_devices").fetchone()
        self.assertEqual((row["token"], row["recovery_sends"]), ("ef" * 32, 0))

    def register(self):
        return self.store.push_device(self.client["credential"], {
            "deviceToken": self.device_token, "environment": "development"})

    def emit(self, state, at=100):
        revision = self.store.emit(state)
        with self.store.connect() as db:
            db.execute("UPDATE events SET at=? WHERE seq=?", (at, revision))
        return revision

    def test_activity_state_sets_attention_without_removing_watch_events(self):
        for state in ("working", "idle", "needs_input", "finished", "failed"):
            with self.subTest(state=state):
                payload, headers = notification("source", "generation", {"seq": 1, "at": 100, "state": state}, 100)
                passive = state in ("working", "idle")
                self.assertIn("alert", payload["aps"])
                self.assertNotIn("content-available", payload["aps"])
                self.assertEqual(headers["apns-push-type"], "alert")
                self.assertEqual(payload["aps"].get("interruption-level", "active"), "passive" if passive else "active")
                self.assertEqual("sound" in payload["aps"], not passive)

    def test_notification_copy_uses_event_context_without_private_labels(self):
        event = {"seq": 1, "at": 100, "state": "finished", "label": "secret prompt",
                 "payload": json.dumps({"sourceName": "Omarchy", "sessions": [
                     {"provider": "codex", "state": "finished", "id": "secret/path"}]})}
        payload, _ = notification("source", "generation", event, 100)
        self.assertEqual(payload["aps"]["alert"], {"title": "Codex finished its turn", "body": "Omarchy"})
        self.assertNotIn("secret", json.dumps(payload))
        event["state"] = "needs_input"
        event["payload"] = json.dumps({"sourceName": "Omarchy", "sessions": [
            {"provider": "codex", "state": "needs_input"},
            {"provider": "claude", "state": "needs_input"},
            {"provider": "codex", "state": "working"}]})
        payload, _ = notification("source", "generation", event, 100)
        self.assertEqual(payload["aps"]["alert"]["title"], "2 sessions need input")
        self.assertEqual(payload["aps"]["alert"]["body"], "Omarchy · 1 working")
        event["state"] = "failed"
        event["payload"] = json.dumps({"sourceName": "Omarchy", "sessions": [
            {"provider": "codex", "state": "failed"}]})
        payload, _ = notification("source", "generation", event, 100)
        self.assertEqual(payload["aps"]["alert"], {"title": "Codex turn failed", "body": "Omarchy"})

    def test_phone_names_are_scoped_to_each_push_destination(self):
        other = self.pair()
        self.store.push_device(self.client["credential"], {"deviceToken": self.device_token,
            "environment": "development", "displayName": "Studio Mac"})
        self.store.push_device(other["credential"], {"deviceToken": "cd" * 32,
            "environment": "development", "displayName": "Travel Mac"})
        revision = self.emit("needs_input")
        with self.store.connect() as db:
            db.execute("UPDATE events SET payload=? WHERE seq=?",
                       (json.dumps({"sourceName": "reported-host"}), revision))
        self.worker.step(100)
        bodies = {call[0]["token"]: call[1]["aps"]["alert"]["body"] for call in self.sender.calls}
        self.assertEqual(bodies, {self.device_token: "Studio Mac", "cd" * 32: "Travel Mac"})
        self.store.push_device(self.client["credential"], {"deviceToken": self.device_token,
            "environment": "development", "displayName": ""})
        self.assertEqual(self.store.push_device(other["credential"])["registered"], True)
        with self.store.connect() as db:
            names = dict(db.execute("SELECT id,display_name FROM clients"))
        self.assertIsNone(names[self.client["clientID"]])
        self.assertEqual(names[other["clientID"]], "Travel Mac")
        self.assertEqual(notification("source", "generation", {"seq": 1, "state": "working", "at": 100,
            "payload": json.dumps({"sourceName": "reported-host"})}, 100)[0]["aps"]["alert"]["body"],
            "reported host")

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

    def test_alert_has_hint_without_background_wake_request_or_private_content(self):
        revision = self.emit("needs_input")
        self.worker.step(100)
        _, payload, headers, _ = self.sender.calls[0]
        self.assertNotIn("content-available", payload["aps"])
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
        self.assertEqual(self.sender.calls[0][1]["aps"]["alert"]["title"], "Agent is working")
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
        self.assertNotIn("content-available", payload["aps"])
        self.assertEqual(payload["aps"]["alert"]["title"], "Agent is working")
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
        self.assertEqual(self.sender.calls[-1][1]["aps"]["alert"]["title"], "Agent finished its turn")
        self.emit("idle", 130)
        worker.step(130)
        self.assertEqual(len(self.sender.calls), 4)
        aps = self.sender.calls[-1][1]["aps"]
        self.assertEqual(aps["alert"]["title"], "No active sessions")
        self.assertEqual(aps["interruption-level"], "passive")
        self.assertNotIn("sound", aps)

    def test_repeated_working_finished_cycles_have_distinct_notification_identities(self):
        for at, state in ((100, "working"), (120, "finished"), (140, "working"), (160, "finished")):
            self.emit(state, at)
            self.worker.step(at)
        identities = [call[2]["apns-collapse-id"] for call in self.sender.calls]
        self.assertEqual(len(identities), 4)
        self.assertEqual(len(set(identities)), 4)
        self.assertTrue(all(len(value.encode()) <= 64 for value in identities))
        self.assertEqual(len({call[1]["aps"]["thread-id"] for call in self.sender.calls}), 1)

    def test_retry_after_restart_reuses_notification_identity(self):
        self.emit("finished", 100)
        self.sender.result = Result(503, "ServiceUnavailable", "retry-id")
        self.worker.step(100)
        self.sender.result = Result(200, "Accepted", "accepted-id")
        Worker(Store(self.store.path), self.sender, self.log).step(111)
        self.assertEqual(len(self.sender.calls), 2)
        self.assertEqual(self.sender.calls[0][2]["apns-collapse-id"], self.sender.calls[1][2]["apns-collapse-id"])

    def test_notification_identity_is_scoped_to_source_and_generation(self):
        event = {"seq": 1, "state": "finished", "at": 100}
        identities = {
            notification(source, generation, event, 100)[1]["apns-collapse-id"]
            for source, generation in (("source-a", "generation-a"), ("source-b", "generation-a"),
                                       ("source-a", "generation-b"))
        }
        self.assertEqual(len(identities), 3)

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

    def test_watch_allowance_push_uses_current_reading_and_respects_budget(self):
        now = 1_800_000_000
        token = "ef" * 32
        self.assertEqual(self.store.watch_push_device(self.client["credential"], {
            "deviceToken": token, "environment": "development"}), {"registered": True})
        allowance = {"provider": "codex", "remaining": 64, "window": 1,
                     "windowDurationMins": 10080, "updatedAt": now, "resetsAt": now + 500000}
        with self.store.connect() as db:
            db.execute("UPDATE events SET payload=? WHERE seq=(SELECT MAX(seq) FROM events)",
                       (json.dumps({"allowance": allowance}),))
        self.worker.step(now)
        watch = [call for call in self.sender.calls if call[0].get("mode") == "watch"]
        self.assertEqual(len(watch), 1)
        self.assertEqual(watch[0][0]["token"], token)
        self.assertEqual(watch[0][1]["allowance"], allowance)
        self.assertEqual(watch[0][1]["aps"], {"content-available": 1})
        self.assertEqual(watch[0][2]["apns-push-type"], "background")
        self.assertEqual(watch[0][2]["apns-priority"], "5")
        self.worker.step(now + 1201)
        self.assertEqual(len([call for call in self.sender.calls if call[0].get("mode") == "watch"]), 1)
        allowance["remaining"] = 61
        allowance["updatedAt"] = now + 1201
        with self.store.connect() as db:
            db.execute("UPDATE events SET payload=? WHERE seq=(SELECT MAX(seq) FROM events)",
                       (json.dumps({"allowance": allowance}),))
        self.worker.step(now + 1201)
        self.assertEqual(len([call for call in self.sender.calls if call[0].get("mode") == "watch"]), 2)
        self.assertEqual(watch[0][1]["allowance"]["remaining"], 64)

    def test_unchanged_watch_reading_retries_per_client_and_prioritizes_changes(self):
        now = 1_800_000_000
        first_token, second_token = "ef" * 32, "cd" * 32
        self.store.watch_push_device(self.client["credential"], {
            "deviceToken": first_token, "environment": "development"})
        other = self.pair()
        self.store.watch_push_device(other["credential"], {
            "deviceToken": second_token, "environment": "development"})
        allowance = {"provider": "codex", "remaining": 64, "window": 1,
                     "windowDurationMins": 10080, "updatedAt": now, "resetsAt": now + 500000}
        def publish():
            with self.store.connect() as db:
                db.execute("UPDATE events SET payload=? WHERE seq=(SELECT MAX(seq) FROM events)",
                           (json.dumps({"allowance": allowance}),))
        def watch_calls():
            return [call for call in self.sender.calls if call[0].get("mode") == "watch"]

        publish()
        self.worker.step(now)
        self.assertEqual({call[0]["token"] for call in watch_calls()}, {first_token, second_token})
        with self.store.connect() as db:
            db.execute("UPDATE watch_push_devices SET next_attempt=? WHERE client_id=?",
                       (now + 3600, other["clientID"]))
        self.worker.step(now + 1800)
        self.assertEqual([call[0]["token"] for call in watch_calls()[2:]], [first_token])
        allowance["updatedAt"] = now + 3600
        publish()
        self.worker.step(now + 3600)
        self.assertEqual([call[0]["token"] for call in watch_calls()[3:]], [second_token])
        allowance["updatedAt"] = now + 7200
        publish()
        self.worker.step(now + 7200)
        self.assertEqual(len(watch_calls()), 4)
        allowance["remaining"] = 63
        publish()
        self.worker.step(now + 7201)
        self.assertEqual({call[0]["token"] for call in watch_calls()[4:]}, {first_token, second_token})
        with self.store.connect() as db:
            self.assertEqual([row[0] for row in db.execute(
                "SELECT recovery_sends FROM watch_push_devices ORDER BY client_id")], [0, 0])

    def test_unchanged_watch_reading_retries_sparsely(self):
        now = 1_800_000_000
        self.store.watch_push_device(self.client["credential"], {
            "deviceToken": "ef" * 32, "environment": "development"})
        allowance = {"provider": "codex", "remaining": 64, "window": 1,
                     "windowDurationMins": 10080, "updatedAt": now, "resetsAt": now + 500000}

        def step(at):
            allowance["updatedAt"] = at
            with self.store.connect() as db:
                db.execute("UPDATE events SET payload=? WHERE seq=(SELECT MAX(seq) FROM events)",
                           (json.dumps({"allowance": allowance}),))
            self.worker.step(at)
            return len([call for call in self.sender.calls if call[0].get("mode") == "watch"])

        self.assertEqual(step(now), 1)
        self.assertEqual(step(now + 1799), 1)
        self.assertEqual(step(now + 1800), 2)
        self.assertEqual(step(now + 8999), 2)
        self.assertEqual(step(now + 9000), 3)
        self.assertEqual(step(now + 23399), 3)
        self.assertEqual(step(now + 23400), 4)
        self.assertEqual(step(now + 37799), 4)
        self.assertEqual(step(now + 37800), 5)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT recovery_sends FROM watch_push_devices").fetchone()[0], 4)

    def test_failed_watch_recovery_does_not_consume_the_retry(self):
        now = 1_800_000_000
        self.store.watch_push_device(self.client["credential"], {
            "deviceToken": "ef" * 32, "environment": "development"})
        allowance = {"provider": "codex", "remaining": 64, "window": 1,
                     "windowDurationMins": 10080, "updatedAt": now, "resetsAt": now + 500000}
        def publish():
            with self.store.connect() as db:
                db.execute("UPDATE events SET payload=? WHERE seq=(SELECT MAX(seq) FROM events)",
                           (json.dumps({"allowance": allowance}),))
        publish()
        self.worker.step(now)
        self.sender.result = Result(503, "ServiceUnavailable", "failed-retry")
        self.worker.step(now + 1800)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT recovery_sends FROM watch_push_devices").fetchone()[0], 0)
        allowance["updatedAt"] = now + 1831
        publish()
        self.sender.result = Result(200, "Accepted", "recovered")
        self.worker.step(now + 1831)
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT recovery_sends FROM watch_push_devices").fetchone()[0], 1)
        self.assertEqual(len([call for call in self.sender.calls if call[0].get("mode") == "watch"]), 3)

    def test_watch_registration_is_separate_and_revocation_clears_it(self):
        token = "ef" * 32
        self.store.watch_push_device(self.client["credential"], {
            "deviceToken": token, "environment": "development"})
        self.assertTrue(self.store.push_device(self.client["credential"])["registered"])
        self.store.revoke(self.client["clientID"])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM watch_push_devices").fetchone()[0], 0)
        self.assertIsNone(self.store.watch_push_device(self.client["credential"]))


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

    def test_relay_routes_each_environment_to_its_own_apns_host(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "apns.p8").write_bytes(self.pem)
        base = {"teamID": self.config.team_id, "keyID": self.config.key_id,
                "topic": self.config.topic, "keyPath": "apns.p8"}
        path = root / "apns.json"
        path.write_text(json.dumps({"environments": {
            environment: {**base, "environment": environment,
                          "topic": self.config.topic + (".dev" if environment == "development" else "")}
            for environment in ("development", "production")}}))
        router = APNsRouter.load(path)
        self.addCleanup(router.close)
        requests = []
        client = self.httpx.Client(transport=self.httpx.MockTransport(
            lambda request: (requests.append(request), self.httpx.Response(200))[1]))
        self.addCleanup(client.close)
        for sender in router.senders.values():
            sender.client.close()
            sender.watch_client.close()
            sender.client = sender.watch_client = client
        for environment in ("development", "production"):
            result = router.send({"token": "ab" * 32, "environment": environment},
                                 {}, {"apns-id": environment}, 100)
            self.assertEqual(result.status, 200)
        self.assertEqual([request.url.host for request in requests],
                         ["api.sandbox.push.apple.com", "api.push.apple.com"])
        self.assertEqual([request.headers["apns-topic"] for request in requests],
                         [self.config.topic + ".dev", self.config.topic])
        path.write_text(json.dumps({"environments": {"production": {
            **base, "environment": "development"}}}))
        with self.assertRaises(ValueError):
            APNsRouter.load(path)

    def test_http_request_and_jwt_signature_then_refresh(self):
        calls = []
        def handle(request):
            calls.append(request)
            return self.httpx.Response(200)
        sender = APNs(self.config, self.httpx.Client(transport=self.httpx.MockTransport(handle)))
        self.addCleanup(sender.close)
        payload, headers = notification("source", "generation", {"seq": 1, "state": "finished", "at": 100}, 100)
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

    def test_watch_push_uses_watch_topic(self):
        calls = []
        sender = APNs(self.config, self.httpx.Client(transport=self.httpx.MockTransport(
            lambda request: (calls.append(request), self.httpx.Response(200))[1])))
        self.addCleanup(sender.close)
        payload, headers = watch_allowance_notification("source", {
            "provider": "codex", "remaining": 64, "window": 1,
            "windowDurationMins": 10080, "updatedAt": 100, "resetsAt": 200}, 100)
        sender.send({"token": "ab" * 32, "environment": "development", "mode": "watch"}, payload, headers, 100)
        self.assertEqual(calls[0].headers["apns-topic"], self.config.topic + ".watchkitapp")

    def test_watch_key_is_separate_from_phone_key(self):
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives import serialization
        watch_key = ec.generate_private_key(ec.SECP256R1())
        watch_pem = watch_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                            serialization.NoEncryption())
        config = Config(self.config.team_id, self.config.key_id, self.config.topic,
                        self.config.environment, self.pem, "ZYXWVUTSRQ", watch_pem)
        calls = []
        sender = APNs(config, self.httpx.Client(transport=self.httpx.MockTransport(
            lambda request: (calls.append(request), self.httpx.Response(200))[1])))
        self.addCleanup(sender.close)
        device = {"token": "ab" * 32, "environment": "development"}
        sender.send(device, {}, {"apns-id": "phone"}, 100)
        sender.send({**device, "mode": "watch"}, {}, {"apns-id": "watch"}, 100)
        phone_jwt, watch_jwt = (request.headers["authorization"].removeprefix("bearer ") for request in calls)
        self.assertEqual(self.jwt.get_unverified_header(phone_jwt)["kid"], config.key_id)
        self.assertEqual(self.jwt.get_unverified_header(watch_jwt)["kid"], config.watch_key_id)
        self.jwt.decode(phone_jwt, self.key.public_key(), algorithms=["ES256"])
        self.jwt.decode(watch_jwt, watch_key.public_key(), algorithms=["ES256"])

    def test_optional_watch_key_configuration(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "phone.p8").write_bytes(self.pem)
        (root / "watch.p8").write_bytes(self.pem)
        (root / "phone.p8").chmod(0o600)
        (root / "watch.p8").chmod(0o600)
        config_file = root / "apns.json"
        value = {"teamID": self.config.team_id, "keyID": self.config.key_id,
                 "topic": self.config.topic, "environment": "development", "keyPath": "phone.p8",
                 "watchKeyID": "ZYXWVUTSRQ", "watchKeyPath": "watch.p8"}
        config_file.write_text(json.dumps(value))
        self.assertEqual(Config.load(config_file).watch_key_id, "ZYXWVUTSRQ")
        del value["watchKeyPath"]
        config_file.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "both watchKeyID and watchKeyPath"):
            Config.load(config_file)

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
