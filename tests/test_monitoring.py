from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch

from tests.identity import device
from service.hub import Store
from service.push import (Result, Worker, live_notification, live_start_notification,
                          should_end_live_activity)
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

    def test_existing_live_activity_tables_gain_alert_cursor(self):
        path = Path(self.tmp.name) / 'old-live.sqlite3'
        with closing(sqlite3.connect(path)) as db, db:
            db.execute('CREATE TABLE live_activities (client_id TEXT PRIMARY KEY, activity_id TEXT, '
                       'token TEXT, environment TEXT, cursor INTEGER, expires REAL, '
                       'next_attempt REAL, attempts INTEGER)')
            db.execute('CREATE TABLE live_activity_starts (client_id TEXT PRIMARY KEY, token TEXT, '
                       'environment TEXT, cursor INTEGER, next_attempt REAL, attempts INTEGER)')
            db.execute("INSERT INTO live_activities VALUES ('paired-phone', 'activity-1', 'token', "
                       "'development', 7, 1000, 0, 0)")
        Store(path)
        with closing(sqlite3.connect(path)) as db, db:
            for table in ('live_activities', 'live_activity_starts'):
                self.assertIn('alert_cursor',
                              {row[1] for row in db.execute(f'PRAGMA table_info({table})')})
            self.assertTrue({'rejected_reason', 'rejected_at'} <=
                            {row[1] for row in db.execute('PRAGMA table_info(live_activity_starts)')})
            self.assertEqual(db.execute("SELECT activity_id,cursor,alert_cursor FROM live_activities "
                                        "WHERE client_id='paired-phone'").fetchone(),
                             ('activity-1', 7, 0))

    def test_registration_is_independent_and_removal_is_scoped(self):
        self.store.push_device(self.credential, {'deviceToken': 'cd'*32, 'environment': 'development'})
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

    def test_attention_update_bypasses_regular_live_cadence(self):
        now = time.time()
        self.store.emit('working')
        self.register()
        self.worker.step(now)
        latest = self.store.emit('needs_input')
        self.worker.step(now + 1)
        self.assertEqual(len(self.sender.calls), 2)
        self.assertEqual(self.sender.calls[-1][1]['aps']['alert']['sound'], 'PacemanInput.wav')
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

    def test_terminal_grace_uses_activity_change_not_observation(self):
        for state in ('finished', 'failed'):
            for sessions in (None, [], [{'state': state}]):
                with self.subTest(state=state, sessions=sessions):
                    snapshot = dict(state=state, changedAt=100, observedAt=189, sessions=sessions)
                    self.assertFalse(should_end_live_activity(snapshot, 189))
                    snapshot['observedAt'] = 190  # Fresh contact does not restart the grace.
                    self.assertTrue(should_end_live_activity(snapshot, 190))
        self.assertTrue(should_end_live_activity(dict(state='idle', sessions=[], changedAt=190), 190))

    def test_mixed_failure_keeps_activity_and_allows_remote_start(self):
        now = time.time()
        self.store.emit('failed')
        snapshot = self.store.snapshot()
        snapshot.update(changedAt=now - 600, sessions=[{'state': 'failed'}, {'state': 'working'}])
        self.register()
        self.worker.step_live_activities(now, snapshot)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'update')
        self.assertEqual(self.sender.calls[-1][1]['aps']['content-state']['working'], 1)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM live_activities').fetchone()[0], 1)
        # The same ongoing work is eligible for a remote start when no activity exists.
        self.store.live_activity(self.credential, {'activityID': 'activity-1', 'action': 'remove'})
        self.store.live_activity(self.credential, {
            'action': 'register-start', 'deviceToken': 'cd' * 32, 'environment': 'development'})
        self.worker.step_live_activities(now + 1, snapshot)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'start')
        self.assertEqual(self.sender.calls[-1][1]['aps']['content-state']['working'], 1)
        snapshot['sessions'][-1]['state'] = 'needs_input'
        self.assertFalse(should_end_live_activity(snapshot, now + 600))

    def test_failed_activity_ends_without_restarting_until_new_work(self):
        now = time.time()
        self.store.emit('failed')
        snapshot = {**self.store.snapshot(), 'changedAt': now}
        self.store.live_activity(self.credential, {
            'action': 'register-start', 'deviceToken': 'cd' * 32, 'environment': 'development'})
        self.register()
        self.worker.step_live_activities(now, snapshot)
        self.worker.step_live_activities(now + 89, snapshot)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'update')
        self.worker.step_live_activities(now + 90, snapshot)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'end')
        sent = len(self.sender.calls)
        self.worker.step_live_activities(now + 91, snapshot)
        self.assertEqual(len(self.sender.calls), sent)
        self.store.emit('working')
        snapshot = {**self.store.snapshot(), 'observedAt': now + 92, 'changedAt': now + 92}
        self.worker.step_live_activities(now + 92, snapshot)
        self.assertEqual(self.sender.calls[-1][1]['aps']['event'], 'start')
        self.assertEqual(self.sender.calls[-1][1]['aps']['content-state']['working'], 1)

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
        self.assertEqual(payload['aps']['content-state']['providers'], ['other'])

    def test_live_attention_owns_one_phone_sound_and_watch_entry_stays_passive(self):
        now = time.time()
        self.store.push_device(self.credential, {'deviceToken': 'cd' * 32,
            'environment': 'development'})
        self.store.emit('working')
        self.register()
        self.worker.step(now)
        self.assertEqual(self.sender.calls[0][1]['aps']['alert']['sound'], 'PacemanWorking.wav')
        event = self.store.emit('needs_input')
        self.worker.step(now + 1)
        self.assertEqual(self.sender.calls[-1][1]['aps']['alert']['sound'], 'PacemanInput.wav')
        self.worker.step(now + 16)
        live, ordinary = self.sender.calls[-2:]
        self.assertEqual(live[1]['aps']['alert']['sound'], 'PacemanInput.wav')
        self.assertEqual(live[2]['apns-priority'], '10')
        self.assertEqual(ordinary[1]['aps']['interruption-level'], 'passive')
        self.assertNotIn('sound', ordinary[1]['aps'])
        self.assertEqual(ordinary[1]['companion']['revision'], event)
        self.worker.step(now + 257)
        self.assertNotIn('alert', self.sender.calls[-1][1]['aps'])

    def test_failed_live_send_leaves_ordinary_attention_active(self):
        class LiveFailureSender(FakeSender):
            def send(self, device, payload, headers, now):
                self.calls.append((device, payload, headers, now))
                return (Result(503, 'ServiceUnavailable', 'failed') if device.get('mode') == 'liveactivity'
                        else Result(200, 'Accepted', 'ordinary'))

        now = time.time()
        self.store.push_device(self.credential, {'deviceToken': 'cd' * 32,
            'environment': 'development'})
        self.register()
        self.store.emit('needs_input')
        sender = LiveFailureSender()
        worker = Worker(self.store, sender, Path(self.tmp.name) / 'failure.jsonl')
        worker.step(now + 1)
        self.assertEqual(sender.calls[0][1]['aps']['alert']['sound'], 'PacemanInput.wav')
        self.assertEqual(sender.calls[1][1]['aps']['sound'], 'default')
        worker.step(now + 17)
        self.assertNotIn('alert', sender.calls[-1][1]['aps'])

    def test_remote_start_sound_is_not_replayed_when_update_token_arrives(self):
        now = time.time()
        self.store.push_device(self.credential, {'deviceToken': 'ef' * 32,
            'environment': 'development'})
        self.store.live_activity(self.credential, {'action': 'register-start',
            'deviceToken': 'cd' * 32, 'environment': 'development'})
        self.store.emit('failed')
        self.worker.step(now + 1)
        start, ordinary = self.sender.calls
        self.assertEqual(start[1]['aps']['alert']['sound'], 'PacemanFailed.wav')
        self.assertNotIn('sound', ordinary[1]['aps'])
        self.register()
        self.worker.step(now + 2)
        self.assertNotIn('alert', self.sender.calls[-1][1]['aps'])

    def test_live_activity_names_only_known_agent_types(self):
        snapshot = self.store.snapshot()
        snapshot['sessions'] = [
            {'state': 'working', 'provider': 'codex', 'name': 'PRIVATE PROMPT'},
            {'state': 'finished', 'provider': 'claude-code', 'project': '/private/work'},
            {'state': 'idle', 'provider': 'private-agent'},
        ]
        content = live_notification(snapshot, time.time())[0]['aps']['content-state']
        self.assertEqual(content['providers'], ['claude', 'codex'])
        self.assertNotIn('PRIVATE PROMPT', json.dumps(content))
        self.assertNotIn('/private/work', json.dumps(content))

    def test_live_activity_shows_only_a_shared_path_free_workspace_label(self):
        snapshot = self.store.snapshot()
        snapshot['sessions'] = [
            {'state': 'needs_input', 'provider': 'codex', 'workspaceLabel': 'paceman'},
            {'state': 'working', 'provider': 'codex', 'workspaceLabel': 'paceman'},
        ]
        content = live_notification(snapshot, time.time())[0]['aps']['content-state']
        self.assertEqual(content['workspaceLabel'], 'paceman')
        snapshot['sessions'][1]['workspaceLabel'] = 'another-project'
        self.assertNotIn('workspaceLabel', live_notification(snapshot, time.time())[0]['aps']['content-state'])
        snapshot['sessions'][1]['workspaceLabel'] = '/private/project'
        self.assertNotIn('workspaceLabel', live_notification(snapshot, time.time())[0]['aps']['content-state'])

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

    def test_rejected_start_token_stays_recorded_until_replaced(self):
        now = time.time()
        registration = {'action': 'register-start', 'deviceToken': 'cd' * 32,
                        'environment': 'production'}
        self.store.live_activity(self.credential, registration)
        self.store.emit('working')
        self.sender.result = Result(400, 'BadDeviceToken', 'test-apns-id')
        self.worker.step(now + 1)
        with self.store.connect() as db:
            row = db.execute('SELECT token,environment,rejected_reason,rejected_at,next_attempt '
                             'FROM live_activity_starts').fetchone()
        self.assertEqual((row['token'], row['environment'], row['rejected_reason']),
                         ('cd' * 32, 'production', 'BadDeviceToken'))
        self.assertEqual(row['rejected_at'], now + 1)
        self.assertEqual(row['next_attempt'], now + 1 + 24 * 3600)

        self.store.live_activity(self.credential, registration)
        self.store.emit('idle')
        self.worker.step(now + 2)
        self.store.emit('working')
        self.worker.step(now + 3)
        self.assertEqual(len(self.sender.calls), 1)

        self.store.live_activity(self.credential, {**registration, 'deviceToken': 'ef' * 32})
        self.sender.result = Result(200, 'Accepted', 'next-apns-id')
        self.worker.step(now + 4)
        self.assertEqual(len(self.sender.calls), 2)
        self.assertEqual(self.sender.calls[-1][0]['token'], 'ef' * 32)
        with self.store.connect() as db:
            row = db.execute('SELECT rejected_reason,rejected_at FROM live_activity_starts').fetchone()
        self.assertIsNone(row['rejected_reason'])
        self.assertIsNone(row['rejected_at'])

    def test_rejected_start_token_can_recover_after_configuration_fix(self):
        now = time.time()
        self.store.live_activity(self.credential, {
            'action': 'register-start', 'deviceToken': 'cd' * 32,
            'environment': 'production'})
        self.store.emit('working')
        self.sender.result = Result(400, 'DeviceTokenNotForTopic', 'first-apns-id')
        self.worker.step(now + 1)
        self.store.emit('idle')
        self.worker.step(now + 2)
        self.store.emit('working')
        self.sender.result = Result(200, 'Accepted', 'next-apns-id')
        with patch('service.hub.time.time', return_value=now + 24 * 3600 + 1):
            self.worker.step(now + 24 * 3600 + 2)
        self.assertEqual(len(self.sender.calls), 2)
        with self.store.connect() as db:
            row = db.execute('SELECT rejected_reason,rejected_at FROM live_activity_starts').fetchone()
        self.assertIsNone(row['rejected_reason'])
        self.assertIsNone(row['rejected_at'])

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

    def test_remote_start_uses_this_phones_computer_name(self):
        now = time.time()
        self.store.live_activity(self.credential, {
            'action': 'register-start', 'deviceToken': 'cd' * 32,
            'environment': 'development', 'displayName': 'Studio Mac'})
        self.store.emit('working')
        self.worker.step(now + 1)
        start = next(call[1] for call in self.sender.calls if call[1]['aps'].get('event') == 'start')
        self.assertEqual(start['aps']['alert']['title'], 'Agent is working')
        self.assertEqual(start['aps']['alert']['body'], 'Studio Mac')
        self.assertEqual(start['aps']['alert']['sound'], 'PacemanWorking.wav')
        self.assertEqual(start['aps']['attributes']['sourceName'], 'Studio Mac')

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

    def test_removing_one_computers_start_registration_keeps_other_computer_enabled(self):
        second = Store(Path(self.tmp.name) / 'second.sqlite3')
        second_client = second.redeem(second.invite('https://second.example')['invitation'], device=device())
        registration = {'action': 'register-start', 'deviceToken': 'cd' * 32,
                        'environment': 'development'}
        self.store.live_activity(self.credential, registration)
        second.live_activity(second_client['credential'], registration)
        self.assertEqual(self.store.live_activity(self.credential, {'action': 'remove-start'}),
                         {'registered': False})
        self.store.emit('working')
        second.emit('working')
        now = time.time() + 1
        self.worker.step(now)
        Worker(second, self.sender, Path(self.tmp.name) / 'second-push.jsonl').step(now)
        starts = [call[1]['aps'] for call in self.sender.calls if call[1]['aps']['event'] == 'start']
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0]['attributes']['sourceID'], second.metadata('source_id'))
