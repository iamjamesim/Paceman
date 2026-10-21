import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from service.hub import Store
from service.macos import MacSource
from service.session_history import (completed_sessions, display_sessions, retained_completions,
    COMPLETED_RETENTION, FINISHED_DISPLAY_DURATION, MAX_COMPLETED_SESSIONS)


class SessionHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = self.enterContext(tempfile.TemporaryDirectory())
        self.path = Path(self.temp) / 'hub.sqlite3'
        self.store = Store(self.path)

    def record(self, sessions, now, providers=None):
        with self.store.connect() as db:
            return completed_sessions(db, sessions, now, providers)

    def session(self, state='finished', **extra):
        return dict(id='one', provider='codex', state=state, **extra)

    def test_result_observation_does_not_renew_with_metadata_or_restart(self):
        first = self.record([self.session(name='Original title')], 100)
        self.store = Store(self.path)
        newer_title = self.record([self.session(name='Renamed')], 200)
        self.assertEqual(newer_title[0]['resultObservedAt'], first[0]['resultObservedAt'])
        self.assertEqual(newer_title[0]['name'], 'Renamed')
        self.assertEqual(self.record([], 100 + COMPLETED_RETENTION - 1), newer_title)
        self.assertEqual(self.record([], 100 + COMPLETED_RETENTION), [])

    def test_new_activity_supersedes_result_but_absence_does_not(self):
        self.record([self.session()], 100)
        self.assertEqual(len(self.record([], 200)), 1)
        self.assertEqual(self.record([self.session('working')], 300), [])
        self.assertEqual(self.record([self.session('failed')], 400)[0]['resultObservedAt'], 400)
        self.assertEqual(self.record([], 500, providers=['claude']), [])

    def test_closed_agent_keeps_glance_then_moves_to_retained_history(self):
        result = self.record([self.session()], 100)
        self.assertEqual(display_sessions([], result, 100 + FINISHED_DISPLAY_DURATION - 1), result)
        self.assertEqual(display_sessions([], result, 100 + FINISHED_DISPLAY_DURATION), [])
        self.assertEqual(retained_completions(result, result), [])
        self.assertEqual(retained_completions([], result), result)
        self.assertEqual(len(display_sessions(result, result, 101)), 1)

    def test_count_and_wire_payload_are_bounded(self):
        for index in range(MAX_COMPLETED_SESSIONS + 10):
            value = dict(id=str(index), provider='codex', state='finished', name='界' * 80)
            rows = self.record([value], index + 100)
        self.assertEqual(len(rows), MAX_COMPLETED_SESSIONS)
        self.assertEqual(rows[0]['id'], str(MAX_COMPLETED_SESSIONS + 9))
        wire = retained_completions([], rows)
        self.assertLessEqual(len(json.dumps(wire).encode()), 25 * 1024)
        self.assertGreater(len(wire), 0)

    def test_upgrade_recovers_only_already_observed_results_and_honors_later_work(self):
        now = time.time()
        with self.store.connect() as db:
            db.execute("DELETE FROM metadata WHERE key='completed_sessions_migrated'")
            for offset, sessions in [(10, [self.session()]), (20, [self.session(name='Renamed')]),
                                     (30, [dict(id='two', provider='claude', state='failed')]),
                                     (40, [dict(id='two', provider='claude', state='working')]), (50, [])]:
                db.execute('INSERT INTO events(at,state,label,payload) VALUES (?,?,?,?)',
                           (now - 100 + offset, 'idle', 'fixture', json.dumps(dict(sessions=sessions))))
        self.store = Store(self.path)
        rows = self.record([], now)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['name'], 'Renamed')
        self.assertEqual(rows[0]['resultObservedAt'], now - 90)

    def test_mac_history_survives_agent_end_and_both_store_and_service_restart(self):
        now = time.time()
        args = dict(socket_path=Path(self.temp) / 'hook.sock', allowance_reader=lambda: None)
        with patch('service.macos.time.time', return_value=now):
            with MacSource(self.store, **args) as source:
                source.receive(dict(command='agent-event', session='one', turn='1', event='completed'))
                source.receive(dict(command='agent-event', session='one', turn='1', event='ended'))
                self.assertEqual(self.store.snapshot()['state'], 'finished')
        with patch('service.macos.time.time', return_value=now + 3600):
            self.store = Store(self.path)
            with MacSource(self.store, **args):
                snapshot = self.store.snapshot()
                self.assertEqual(snapshot['state'], 'idle')
                self.assertEqual(snapshot['sessions'], [])
                self.assertEqual(len(snapshot['completedSessions']), 1)
                self.assertEqual(snapshot['completedSessions'][0]['resultObservedAt'], now)
        with patch('service.macos.time.time', return_value=now + COMPLETED_RETENTION):
            with MacSource(Store(self.path), **args):
                self.assertEqual(self.store.snapshot()['completedSessions'], [])

    def test_recovered_result_does_not_create_a_new_activity_alert(self):
        now = time.time()
        self.record([self.session('failed', resultObservedAt=now - 60)], now)
        before = self.store.snapshot()
        with MacSource(self.store, socket_path=Path(self.temp) / 'hook.sock', allowance_reader=lambda: None):
            recovered = self.store.snapshot()
            self.assertEqual(recovered['state'], 'failed')
            self.assertEqual(recovered['eventID'], before['eventID'])
            with self.store.connect() as db:
                self.assertEqual(db.execute('SELECT kind FROM events ORDER BY seq DESC LIMIT 1').fetchone()[0], 'presentation')
