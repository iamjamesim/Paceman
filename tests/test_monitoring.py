import json
from pathlib import Path
import tempfile
import time
import unittest

from tests.identity import device
from service.hub import Store
from service.push import Worker, live_notification, live_start_notification
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
        now = time.time()
        self.store.emit('working')
        self.register()
        self.worker.step(now)
        latest = self.store.emit('needs_input')
        self.worker.step(now + 1)
        self.assertEqual(len(self.sender.calls), 1)
        self.worker.step(now + 16)
        self.assertEqual(len(self.sender.calls), 2)
        state = self.sender.calls[-1][1]['aps']['content-state']
        self.assertEqual(state['revision'], latest)
        self.assertEqual(state['needsInput'], 1)

    def test_unchanged_work_renews_a_bounded_freshness_lease(self):
        now = time.time()
        self.store.emit('working')
        self.register()
        self.worker.step(now)
        self.worker.step(now + 239)
        self.assertEqual(len(self.sender.calls), 1)
        self.worker.step(now + 241)
        self.assertEqual(len(self.sender.calls), 2)
        first = self.sender.calls[0][1]['aps']['content-state']
        renewed = self.sender.calls[1][1]['aps']['content-state']
        self.assertEqual(first['revision'], renewed['revision'])
        self.assertEqual(renewed['freshUntil'] - renewed['observedAt'], 300)

    def test_eight_hour_expiry_ends_and_removes_destination(self):
        self.store.emit('working')
        self.register()
        self.worker.step(time.time() + 8 * 3600 + 1)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'end')
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM live_activities').fetchone()[0], 0)

    def test_finished_activity_rests_then_ends(self):
        now = time.time()
        self.store.emit('working')
        self.register()
        self.worker.step(now + 1)
        self.store.emit('finished')
        self.worker.step(now + 16)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'update')
        self.worker.step(now + 92)
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

    def test_live_activity_uses_one_display_palette_and_has_state_time(self):
        snapshot = self.store.snapshot()
        snapshot['appearance'] = {'background': '#191724', 'foreground': 'E0DEF4',
                                  'accent': 'EBBCBA', 'monospaced': True,
                                  'name': 'PRIVATE THEME'}
        payload, _ = live_notification(snapshot, time.time())
        content = payload['aps']['content-state']
        self.assertNotIn('background', content)
        self.assertNotIn('foreground', content)
        self.assertNotIn('accent', content)
        self.assertEqual(content['changedAt'], snapshot['changedAt'])
        self.assertGreater(payload['aps']['relevance-score'], 0)
        self.assertNotIn('PRIVATE THEME', json.dumps(payload))

    def test_fresh_input_ranks_above_work_but_stale_input_does_not(self):
        base = self.store.snapshot()
        now = time.time()
        input_snapshot = {**base, 'state': 'needs_input', 'sessions': [{'state': 'needs_input'}],
                          'observedAt': now}
        working_snapshot = {**base, 'state': 'working', 'sessions': [{'state': 'working'}],
                            'observedAt': now + 30}
        input_score = live_notification(input_snapshot, now + 30)[0]['aps']['relevance-score']
        work_score = live_notification(working_snapshot, now + 30)[0]['aps']['relevance-score']
        self.assertGreater(input_score, work_score)
        later_work = live_notification({**working_snapshot, 'observedAt': now + 301},
                                       now + 301)[0]['aps']['relevance-score']
        self.assertGreater(later_work, input_score)

    def test_registration_rejects_invalid_tokens_and_unauthorized_clients(self):
        self.assertIsNone(self.store.live_activity('invalid', self.payload))
        with self.assertRaises(ValueError):
            self.store.live_activity(self.credential, {**self.payload, 'deviceToken': 'secret'})

    def test_remote_start_uses_one_source_and_a_new_update_token(self):
        now = time.time()
        self.store.emit('working')
        self.assertTrue(self.store.live_activity(self.credential, {
            'action': 'register-start', 'deviceToken': 'cd' * 32,
            'environment': 'development'})['registered'])
        self.worker.step(now + 11)
        self.assertEqual(len(self.sender.calls), 1)
        device, payload, headers, _ = self.sender.calls[0]
        self.assertEqual(device['token'], 'cd' * 32)
        self.assertEqual(payload['aps']['event'], 'start')
        self.assertEqual(payload['aps']['attributes-type'], 'MonitoringActivity')
        self.assertEqual(payload['aps']['attributes']['sourceID'], self.store.metadata('source_id'))
        self.assertEqual(payload['aps']['input-push-token'], 1)
        self.assertIn('alert', payload['aps'])
        self.assertEqual(headers['apns-push-type'], 'liveactivity')
        self.register()
        self.store.emit('needs_input')
        self.worker.step(now + 27)
        self.assertEqual(self.sender.calls[-1][0]['token'], 'ab' * 32)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'update')
        self.assertEqual(len([call for call in self.sender.calls if call[1]['aps']['event'] == 'start']), 1)

    def test_remote_start_waits_for_update_token_without_restarting_each_revision(self):
        now = time.time()
        self.store.live_activity(self.credential, {
            'action': 'register-start', 'deviceToken': 'cd' * 32,
            'environment': 'development'})
        self.store.emit('working')
        self.worker.step(now + 1)
        self.store.emit('needs_input')
        self.worker.step(now + 2)
        self.assertEqual(len([call for call in self.sender.calls if call[1]['aps']['event'] == 'start']), 1)
        self.store.emit('idle')
        self.worker.step(now + 3)
        self.store.emit('working')
        self.worker.step(now + 4)
        self.assertEqual(len([call for call in self.sender.calls if call[1]['aps']['event'] == 'start']), 2)

    def test_orphan_recovery_restarts_unchanged_work_only_for_matching_activity(self):
        now = time.time()
        self.store.live_activity(self.credential, {
            'action': 'register-start', 'deviceToken': 'cd' * 32,
            'environment': 'development'})
        self.store.emit('working')
        self.worker.step(now + 1)
        self.register()
        self.store.live_activity(self.credential, {'activityID': 'activity-1', 'action': 'remove'})
        self.worker.step(now + 2)
        self.assertEqual(len([call for call in self.sender.calls if call[1]['aps']['event'] == 'start']), 1)
        self.register()
        self.store.live_activity(self.credential, {'activityID': 'other', 'action': 'recover'})
        self.worker.step(now + 3)
        self.assertEqual(len([call for call in self.sender.calls if call[1]['aps']['event'] == 'start']), 1)
        self.store.live_activity(self.credential, {'activityID': 'activity-1', 'action': 'recover'})
        self.worker.step(now + 4)
        self.assertEqual(len([call for call in self.sender.calls if call[1]['aps']['event'] == 'start']), 2)

    def test_remote_start_clears_on_revocation_and_does_not_expose_tasks(self):
        snapshot = self.store.snapshot()
        snapshot.update(state='working', sourceName='Omarchy', sessions=[{
            'state': 'working', 'name': 'SECRET TASK', 'project': '/private/project'}])
        payload, _ = live_start_notification(snapshot, time.time())
        self.assertNotIn('SECRET TASK', json.dumps(payload))
        self.assertNotIn('/private/project', json.dumps(payload))
        self.store.live_activity(self.credential, {
            'action': 'register-start', 'deviceToken': 'cd' * 32,
            'environment': 'development'})
        self.store.revoke_self(self.credential)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM live_activity_starts').fetchone()[0], 0)

    def test_invalid_start_token_and_unauthorized_registration(self):
        payload = {'action': 'register-start', 'deviceToken': 'cd' * 32, 'environment': 'development'}
        self.assertIsNone(self.store.live_activity('invalid', payload))
        with self.assertRaises(ValueError):
            self.store.live_activity(self.credential, {**payload, 'deviceToken': 'secret'})

    def test_two_computers_start_distinct_activities_for_one_phone(self):
        second = Store(Path(self.tmp.name) / 'second.sqlite3')
        second_client = second.redeem(second.invite('https://second.example')['invitation'], device=device())
        registration = {'action': 'register-start', 'deviceToken': 'cd' * 32,
                        'environment': 'development'}
        self.store.live_activity(self.credential, registration)
        second.live_activity(second_client['credential'], registration)
        self.store.emit('working')
        second.emit('needs_input')
        second_worker = Worker(second, self.sender, Path(self.tmp.name) / 'second-push.jsonl')
        now = time.time() + 1
        self.worker.step(now)
        second_worker.step(now)
        starts = [call[1]['aps'] for call in self.sender.calls if call[1]['aps']['event'] == 'start']
        self.assertEqual(len(starts), 2)
        self.assertEqual({value['attributes']['sourceID'] for value in starts},
                         {self.store.metadata('source_id'), second.metadata('source_id')})
        self.assertEqual({value['content-state']['state'] for value in starts}, {'working', 'needs_input'})
