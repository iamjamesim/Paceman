import json
from pathlib import Path
import tempfile
import time
import unittest

from tests.identity import device
from service.hub import Store
from service.push import Worker, live_notification
from tests.test_push import FakeSender


class MonitoringTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(Path(self.tmp.name) / 'hub.sqlite3')
        self.client = self.store.redeem(self.store.invite('https://source.example')['invitation'], device=device())
        self.credential = self.client['credential']
        self.sender = FakeSender()
        self.worker = Worker(self.store, self.sender, Path(self.tmp.name) / 'push.jsonl')
        self.payload = {'activityID': 'activity-1', 'deviceToken': 'ab' * 32, 'environment': 'development'}

    def register(self):
        return self.store.live_activity(self.credential, self.payload)

    def test_registration_is_independent_and_removal_is_scoped(self):
        self.store.push_device(self.credential, {'deviceToken': 'cd'*32, 'environment': 'development', 'mode': 'alert'})
        self.register()
        self.store.live_activity(self.credential, {'activityID': 'older-activity', 'action': 'remove'})
        self.worker.step()
        self.assertEqual(len(self.sender.calls), 1)
        self.assertEqual(self.sender.calls[0][0]['mode'], 'liveactivity')
        self.store.live_activity(self.credential, {'activityID': 'activity-1', 'action': 'remove'})
        self.assertTrue(self.store.push_device(self.credential)['registered'])
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM live_activities').fetchone()[0], 0)

    def test_revocation_removes_live_destinations(self):
        self.register()
        self.store.revoke_self(self.credential)
        self.worker.step()
        self.assertEqual(self.sender.calls, [])
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM live_activities').fetchone()[0], 0)

    def test_token_rotation_resends_latest_and_stops_old_destination(self):
        self.register()
        self.worker.step()
        self.payload['deviceToken'] = 'ef'*32
        self.register()
        self.worker.step()
        self.assertEqual(len(self.sender.calls), 2)
        self.assertEqual(self.sender.calls[-1][0]['token'], 'ef'*32)

    def test_coalesces_intermediate_revisions(self):
        self.register()
        now = time.time()
        self.worker.step(now)
        self.store.emit('working')
        latest = self.store.emit('needs_input')
        self.worker.step(now + 1)
        self.assertEqual(len(self.sender.calls), 1)
        self.worker.step(now + 16)
        self.assertEqual(len(self.sender.calls), 2)
        state = self.sender.calls[-1][1]['aps']['content-state']
        self.assertEqual(state['revision'], latest)
        self.assertEqual(state['needsInput'], 1)

    def test_probe_expiry_ends_and_removes_destination(self):
        self.register()
        self.worker.step(time.time() + 3601)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'end')
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM live_activities').fetchone()[0], 0)

    def test_payload_is_quiet_and_excludes_private_text(self):
        snapshot = self.store.snapshot()
        snapshot.update(sourceName='PRIVATE', sessions=[{'state': 'working', 'name': 'SECRET', 'project': '/private/project'}])
        payload, headers = live_notification(snapshot, time.time())
        text = json.dumps(payload)
        for value in ('PRIVATE', 'SECRET', '/private', 'sound', 'alert', 'content-available'):
            self.assertNotIn(value, text)
        self.assertEqual(headers['apns-push-type'], 'liveactivity')
        self.assertEqual(headers['apns-priority'], '5')
        self.assertEqual(payload['aps']['content-state']['working'], 1)

    def test_registration_rejects_invalid_tokens_and_unauthorized_clients(self):
        self.assertIsNone(self.store.live_activity('invalid', self.payload))
        with self.assertRaises(ValueError):
            self.store.live_activity(self.credential, {**self.payload, 'deviceToken': 'secret'})
