import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock

from tests.identity import device
from service.hub import Server, Store
from service.omarchy import FINISHED_RETENTION, OmarchySource
from service.push import Worker
from service.status import DesktopStatus
from service.processes import CodexProcesses, ProcessIdentity
from test_push import FakeSender


class OmarchyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store(self.root / 'hub.sqlite3')
        self.owners = {}
        self.processes = Mock(spec=CodexProcesses)
        self.processes.identify.return_value = ProcessIdentity(100, '1', 'test-boot')
        self.processes.is_alive.return_value = True
        self.source = self.enterContext(OmarchySource(self.store,
            socket_path=self.root / 'omarchy-watch.sock', state_dir=self.root / 'omarchy',
            processes=self.processes, computer_name='build-station.example.net'))

    def test_source_reports_computer_identity(self):
        snapshot = self.store.snapshot()
        self.assertEqual(snapshot['sourceName'], 'build-station')
        self.assertNotIn('mode', snapshot)

    def test_allowance_changes_do_not_generate_activity_or_export_other_fields(self):
        import datetime as dt
        path = self.root / 'omarchy/agents/usage/codex.json'
        path.parent.mkdir(parents=True)
        now = int(time.time())
        stamp = lambda epoch: dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()
        before = self.store.snapshot()
        record = {"schemaVersion": 1, "id": "codex", "updatedAt": stamp(now),
                  "privateExtra": "must not leave the source",
                  "limits": [{"label": "5h window", "percent": 0.8, "resetsAt": stamp(now + 3600)}]}
        path.write_text(json.dumps(record))
        self.source.tick(force=True)
        after = self.store.snapshot()
        self.assertEqual(after['allowance'], {"provider": "codex", "remaining": 20,
            "window": 2, "updatedAt": now, "resetsAt": now + 3600})
        self.assertEqual(after['eventID'], before['eventID'])
        self.assertGreater(after['revision'], before['revision'])
        self.assertNotIn('privateExtra', json.dumps(after))
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['revision'], after['revision'])
        path.unlink()
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['allowance'], after['allowance'])
        self.assertEqual(self.store.snapshot()['eventID'], before['eventID'])

    def test_transient_allowance_file_loss_keeps_last_known_value(self):
        import datetime as dt
        allowance = self.root / 'omarchy/agents/usage/codex.json'
        allowance.parent.mkdir(parents=True)
        now = int(time.time())
        stamp = lambda epoch: dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()
        allowance.write_text(json.dumps({"schemaVersion": 1, "id": "codex", "updatedAt": stamp(now),
            "limits": [{"label": "5h window", "percent": 0.25, "resetsAt": stamp(now + 3600)}]}))
        self.source.tick(force=True)
        before = self.store.snapshot()
        allowance.unlink()
        self.source.tick(force=True)
        after = self.store.snapshot()
        self.assertEqual(after['allowance'], before['allowance'])

    def event(self, event, session='one', turn='turn-1', **extra):
        self.owners.setdefault(session, ProcessIdentity(100 + len(self.owners), '1', 'test-boot'))
        self.processes.identify.return_value = self.owners[session]
        body = dict(command='agent-event', source='codex', session=session, turn=turn, event=event, **extra)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(2)
            client.connect(str(self.source.socket_path))
            client.sendall(json.dumps(body).encode() + b'\n')
            response = json.loads(client.recv(4096))
        self.assertTrue(response['ok'])
        return self.store.snapshot()

    def test_socket_routes_all_states_and_does_not_leak_hook_content(self):
        for event, state in [('working', 'working'), ('needs-input', 'needs_input'),
                             ('working', 'working'), ('completed', 'finished'), ('ended', 'idle')]:
            value = self.event(event, prompt='PRIVATE PROMPT', arguments='PRIVATE ARGS')
            self.assertEqual(value['state'], state)
            self.assertNotIn('mode', value)
            self.assertNotIn('PRIVATE', json.dumps(value))
        self.assertEqual(value['sessions'], [])
        self.assertEqual(self.source.socket_path.stat().st_mode & 0o777, 0o600)

    def test_multiple_sessions_and_delayed_cleanup(self):
        self.event('working')
        self.event('needs-input', session='two')
        self.assertEqual(self.event('completed')['state'], 'needs_input')
        self.assertEqual(self.event('working', session='two')['state'], 'working')
        self.event('working', turn='turn-2')
        for event in ('completed', 'needs-input', 'ended', 'interrupted'):
            value = self.event(event, turn='turn-1')
            self.assertEqual(value['state'], 'working')
        self.assertEqual(len(value['sessions']), 2)

    def test_duplicate_events_and_reads_keep_identity(self):
        first = self.event('needs-input')
        second = self.event('needs-input')
        self.source.tick(force=True)
        third = self.store.snapshot()
        for value in (second, third):
            self.assertEqual(first['revision'], value['revision'])
            self.assertEqual(first['eventID'], value['eventID'])
            self.assertEqual(first['changedAt'], value['changedAt'])

    def test_desktop_counts_follow_session_transitions_and_cleanup(self):
        path = self.root / 'status.json'
        status = DesktopStatus(path, self.store)
        def published():
            status.publish(self.source, force=True)
            return json.loads(path.read_text())
        self.event('working')
        self.event('needs-input', session='two')
        value = published()
        self.assertEqual(value['activity'], 'needs_input')
        self.assertEqual(value['sessions'], 2)
        self.assertEqual(value['sessionCounts'], {'needs_input': 1, 'failed': 0, 'working': 1, 'finished': 0, 'idle': 0})
        self.event('completed', session='two')
        value = published()
        self.assertEqual(value['activity'], 'working')
        self.assertEqual(value['sessionCounts'], {'needs_input': 0, 'failed': 0, 'working': 1, 'finished': 1, 'idle': 0})
        self.event('ended', session='two')
        self.assertEqual(published()['sessions'], 1)
        self.event('ended')
        value = published()
        self.assertEqual(value['sessions'], 0)
        self.assertEqual(sum(value['sessionCounts'].values()), 0)

    def test_closed_turn_cannot_be_resurrected_and_session_end_can_omit_turn(self):
        self.event('completed')
        self.assertEqual(self.event('working')['state'], 'finished')
        self.assertEqual(self.event('needs-input')['state'], 'finished')
        self.assertEqual(self.event('ended', turn='')['state'], 'idle')
        self.assertEqual(self.event('needs-input')['state'], 'idle')
        self.assertEqual(self.event('working', turn='turn-2')['state'], 'working')

    def test_async_question_waits_five_seconds_and_ends_with_turn(self):
        clock = [100.0]
        self.source.monotonic = lambda: clock[0]
        self.event('working', hook='UserPromptSubmit')
        opened = self.event('needs-input', attention='async', hook='PreToolUse')
        self.assertEqual(opened['state'], 'working')
        clock[0] += 6
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.assertEqual(self.event('working', hook='PostToolUse')['state'], 'needs_input')
        self.assertEqual(self.event('completed', hook='Stop')['state'], 'finished')
        self.assertEqual(self.event('needs-input', attention='async', hook='PreToolUse')['state'], 'finished')

    def test_short_async_question_does_not_alert(self):
        clock = [100.0]
        self.source.monotonic = lambda: clock[0]
        self.event('working', hook='UserPromptSubmit')
        self.event('needs-input', attention='async', hook='PreToolUse')
        self.assertEqual(self.event('completed', hook='Stop')['state'], 'finished')
        clock[0] += 6
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'finished')

    def test_new_prompt_clears_async_question(self):
        clock = [100.0]
        self.source.monotonic = lambda: clock[0]
        self.event('working', hook='UserPromptSubmit')
        self.event('needs-input', attention='async', hook='PreToolUse')
        clock[0] += 6
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.assertEqual(self.event('working', turn='turn-2', hook='UserPromptSubmit')['state'], 'working')

    def test_finished_turn_disappears_without_losing_live_process_binding(self):
        self.event('working', session='active')
        self.event('completed', session='old')
        before = self.store.snapshot()
        with self.store.connect() as db:
            db.execute("UPDATE omarchy_sessions SET updated=? WHERE state='finished'",
                       (time.time() - FINISHED_RETENTION - 1,))
        self.source.tick(force=True)
        current = self.store.snapshot()
        self.assertEqual(current['state'], 'working')
        self.assertEqual(len(current['sessions']), 1)
        self.assertEqual(current['eventID'], before['eventID'])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM omarchy_processes WHERE closed=0").fetchone()[0], 2)
        resumed = self.event('working', session='old', turn='turn-2')
        self.assertEqual(len(resumed['sessions']), 2)

    def test_allowance_update_does_not_repeat_pending_push(self):
        import datetime as dt
        pair = self.store.redeem(self.store.invite('https://test.example')['invitation'], device=device())
        self.store.push_device(pair['credential'], dict(deviceToken='ab'*32, environment='development'))
        event = self.event('needs-input')
        sender = FakeSender()
        worker = Worker(self.store, sender, self.root / 'push.jsonl')
        worker.step()
        self.assertEqual(sender.calls[0][1]['companion']['eventID'], event['eventID'])
        now = int(time.time())
        stamp = lambda epoch: dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()
        allowance = self.root / 'omarchy/agents/usage/codex.json'
        allowance.parent.mkdir(parents=True)
        allowance.write_text(json.dumps({"schemaVersion": 1, "id": "codex", "updatedAt": stamp(now),
            "limits": [{"label": "5h window", "percent": 0.5, "resetsAt": stamp(now + 3600)}]}))
        self.source.tick(force=True)
        worker.step(now=time.time() + 20)
        self.assertEqual(len(sender.calls), 1)

    def test_restart_retains_pairing_and_live_states_but_clears_unverified_records(self):
        pair = self.store.redeem(self.store.invite('https://test.example')['invitation'], device=device())
        self.event('completed')
        self.event('working', session='two')
        with self.store.connect() as db:
            db.execute("INSERT INTO omarchy_sessions VALUES ('legacy','codex','old','finished',?)", (time.time(),))
        self.source.__exit__(None, None, None)
        self.source.thread = None
        with OmarchySource(Store(self.store.path), socket_path=self.root / 'other.sock',
                           state_dir=self.root / 'omarchy', processes=self.processes):
            value = self.store.snapshot()
            self.assertEqual(value['state'], 'working')
            self.assertEqual(len(value['sessions']), 2)
            self.assertEqual(value['sourceID'], pair['sourceID'])
            self.assertTrue(self.store.authorized(pair['credential']))

    def test_synthetic_controls_are_disabled_and_age_does_not_expire_live_sessions(self):
        with self.assertRaises(ValueError):
            self.store.emit('working')
        with self.store.connect() as db:
            db.execute("INSERT INTO schedule(due,state) VALUES (0,'needs_input')")
        self.store.tick()
        self.assertEqual(self.store.snapshot()['state'], 'idle')
        self.event('working')
        with self.store.connect() as db:
            db.execute('UPDATE omarchy_sessions SET updated=0')
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.processes.is_alive.return_value = False
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'idle')

    def test_live_socket_and_unrelated_file_are_never_replaced(self):
        inode = self.source.socket_path.stat().st_ino
        with self.assertRaisesRegex(ValueError, 'in use'):
            with OmarchySource(self.store, socket_path=self.source.socket_path):
                pass
        self.assertEqual(self.source.socket_path.stat().st_ino, inode)
        path = self.root / 'regular-file'
        path.write_text('keep')
        with self.assertRaises(ValueError):
            with OmarchySource(self.store, socket_path=path):
                pass
        self.assertEqual(path.read_text(), 'keep')

    def test_invalid_or_oversized_socket_commands_are_rejected(self):
        revision = self.store.snapshot()['revision']
        for raw in (b'[]\n', b'{}\n', b'{"command":"pair"}\n', b'x'*4097+b'\n'):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(str(self.source.socket_path))
                client.sendall(raw)
                self.assertFalse(json.loads(client.recv(4096))['ok'])
        self.assertEqual(self.store.snapshot()['revision'], revision)

    def test_paired_snapshots_receive_socket_events_and_revoke(self):
        with Server(('127.0.0.1', 0), self.store, self.source) as server:
            thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=.01), daemon=True)
            thread.start()
            try:
                invitation = self.store.invite('https://test.example')
                conn = http.client.HTTPConnection(*server.server_address, timeout=2)
                self.addCleanup(conn.close)
                conn.request('POST', '/v1/pair', json.dumps({'invitation': invitation['invitation'], 'device': device()}))
                pair = json.loads(conn.getresponse().read())
                headers = {'Authorization': 'Bearer ' + pair['credential']}
                conn.request('GET', '/v1/snapshot', headers=headers)
                initial = json.loads(conn.getresponse().read())
                self.assertNotIn('mode', initial)
                expected = self.event('needs-input')
                conn.request('GET', '/v1/snapshot', headers=headers)
                received = json.loads(conn.getresponse().read())
                self.assertEqual(received['eventID'], expected['eventID'])
                self.store.revoke(pair['clientID'])
                conn.request('GET', '/v1/snapshot', headers=headers)
                response = conn.getresponse()
                self.assertEqual(response.status, 401)
                response.read()
                conn.close()
            finally:
                server.shutdown()
                thread.join(timeout=2)

    def exercise_hook_questions(self, hook):
        def send(name, extra=None, turn='turn-1'):
            payload = dict(hook_event_name=name, session_id='integration', turn_id=turn, **(extra or {}))
            result = subprocess.run([sys.executable, '-I', hook], input=json.dumps(payload), text=True,
                                    capture_output=True, timeout=3,
                                    env={**os.environ, 'XDG_RUNTIME_DIR': str(self.root)})
            self.assertEqual(result.returncode, 0, result.stderr)
            return self.store.snapshot()['state']

        sequence = [('UserPromptSubmit', {}, 'working'),
                    ('PreToolUse', {'tool_name': 'request_user_input', 'tool_use_id': 'call-1'}, 'needs_input'),
                    ('PostToolUse', {'tool_name': 'request_user_input', 'tool_use_id': 'call-1'}, 'working'),
                    ('Stop', {}, 'finished'), ('SessionEnd', {}, 'idle')]
        for name, extra, state in sequence:
            self.assertEqual(send(name, extra), state)
        clock = [100.0]
        self.source.monotonic = lambda: clock[0]
        self.assertEqual(send('UserPromptSubmit', turn='turn-2'), 'working')
        async_tool = {'tool_name': 'request_user_input_async', 'tool_use_id': 'async-1'}
        self.assertEqual(send('PreToolUse', async_tool, 'turn-2'), 'working')
        self.assertEqual(send('PostToolUse', async_tool, 'turn-2'), 'working')
        clock[0] += 6
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.assertEqual(send('Stop', turn='turn-2'), 'finished')

    def test_paceman_hook_routes_blocking_and_async_questions(self):
        hook = Path(__file__).resolve().parents[1] / 'omarchy/codex_hook.py'
        self.exercise_hook_questions(hook)

    def test_paceman_hooks_take_precedence_during_companion_migration(self):
        clock = [100.0]
        self.source.monotonic = lambda: clock[0]
        self.event('working', hook='UserPromptSubmit')  # Older plugin arrived first.
        self.event('working', hook='UserPromptSubmit', adapter='paceman')
        self.event('needs-input', attention='async', adapter='paceman')
        clock[0] += 6
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.assertEqual(self.event('working', hook='UserPromptSubmit')['state'], 'needs_input')
        self.assertEqual(self.event('needs-input')['state'], 'needs_input')
        self.assertEqual(self.event('completed', adapter='paceman')['state'], 'finished')
        # The older plugin can still supply a future turn if Paceman hooks stop.
        self.assertEqual(self.event('working', turn='turn-2')['state'], 'working')

    @unittest.skipUnless(os.environ.get('OMARCHY_CODEX_HOOK'), 'Set OMARCHY_CODEX_HOOK to exercise the upstream companion')
    def test_companion_routes_blocking_and_async_questions(self):
        self.exercise_hook_questions(os.environ['OMARCHY_CODEX_HOOK'])


if __name__ == '__main__':
    unittest.main()
