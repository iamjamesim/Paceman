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
from service.omarchy import OmarchySource, appearance
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
        self.theme = self.root / 'omarchy/current/theme'
        self.theme.mkdir(parents=True)
        self.write_theme()
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
        self.assertEqual(snapshot['mode'], 'omarchy')

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

    def test_transient_profile_file_loss_keeps_last_known_values(self):
        import datetime as dt
        allowance = self.root / 'omarchy/agents/usage/codex.json'
        allowance.parent.mkdir(parents=True)
        now = int(time.time())
        stamp = lambda epoch: dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()
        allowance.write_text(json.dumps({"schemaVersion": 1, "id": "codex", "updatedAt": stamp(now),
            "limits": [{"label": "5h window", "percent": 0.25, "resetsAt": stamp(now + 3600)}]}))
        self.source.tick(force=True)
        before = self.store.snapshot()
        (self.theme / 'colors.toml').unlink()
        allowance.unlink()
        self.source.tick(force=True)
        after = self.store.snapshot()
        self.assertEqual(after['appearance'], before['appearance'])
        self.assertEqual(after['allowance'], before['allowance'])

    def write_theme(self, accent='#FF88AA'):
        (self.theme / 'colors.toml').write_text(f'background="#101010"\nforeground="#FFFFFF"\naccent="{accent}"\n')
        (self.theme.parent / 'theme.name').write_text('Test theme')

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
            self.assertEqual(value['mode'], 'omarchy')
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
        self.assertEqual(value['sessionCounts'], {'needs_input': 1, 'working': 1, 'finished': 0, 'idle': 0})
        self.event('completed', session='two')
        value = published()
        self.assertEqual(value['activity'], 'working')
        self.assertEqual(value['sessionCounts'], {'needs_input': 0, 'working': 1, 'finished': 1, 'idle': 0})
        self.event('ended', session='two')
        self.assertEqual(published()['sessions'], 1)
        self.event('ended')
        value = published()
        self.assertEqual(value['sessions'], 0)
        self.assertEqual(sum(value['sessionCounts'].values()), 0)

    def test_closed_turn_cannot_be_resurrected_and_session_end_can_omit_turn(self):
        self.event('completed')
        self.assertEqual(self.event('working')['state'], 'finished')
        self.assertEqual(self.event('ended', turn='')['state'], 'idle')
        self.assertEqual(self.event('needs-input')['state'], 'idle')
        self.assertEqual(self.event('working', turn='turn-2')['state'], 'working')

    def test_theme_updates_revision_without_realerting(self):
        first = self.event('needs-input')
        self.write_theme('#88FFAA')
        self.source.tick(force=True)
        second = self.store.snapshot()
        self.assertGreater(second['revision'], first['revision'])
        self.assertEqual(second['eventID'], first['eventID'])
        self.assertEqual(second['changedAt'], first['changedAt'])
        self.assertEqual(second['appearance']['accent'], '88FFAA')

    def test_theme_fallback_and_bar_resolution(self):
        (self.theme / 'shell.toml').write_text('[bar]\nbackground="#202020"\ntext="#EEEEEE"\n')
        self.write_theme('#202020')
        value = appearance(self.root / 'omarchy')
        self.assertEqual(value['background'], '202020')
        self.assertEqual(value['accent'], 'EEEEEE')
        (self.theme / 'colors.toml').write_text('invalid toml')
        self.assertIsNone(appearance(self.root / 'omarchy'))

    def test_appearance_cannot_hide_or_repeat_pending_push(self):
        pair = self.store.redeem(self.store.invite('https://test.example')['invitation'], device=device())
        self.store.push_device(pair['credential'], dict(deviceToken='ab'*32, environment='development', mode='alert'))
        event = self.event('needs-input')
        self.write_theme('#88FFAA')
        self.source.tick(force=True)
        sender = FakeSender()
        worker = Worker(self.store, sender, self.root / 'push.jsonl')
        worker.step()
        self.assertEqual(sender.calls[0][1]['companion']['eventID'], event['eventID'])
        self.write_theme('#FFFFFF')
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
                self.assertEqual(initial['mode'], 'omarchy')
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

    @unittest.skipUnless(os.environ.get('OMARCHY_CODEX_HOOK'), 'Set OMARCHY_CODEX_HOOK to exercise the upstream companion')
    def test_existing_companion_routes_without_hook_changes(self):
        hook = os.environ['OMARCHY_CODEX_HOOK']
        sequence = [('UserPromptSubmit', {}, 'working'),
                    ('PreToolUse', {'tool_name': 'request_user_input', 'tool_use_id': 'call-1'}, 'needs_input'),
                    ('PostToolUse', {'tool_name': 'request_user_input', 'tool_use_id': 'call-1'}, 'working'),
                    ('Stop', {}, 'finished'), ('SessionEnd', {}, 'idle')]
        for name, extra, state in sequence:
            payload = dict(hook_event_name=name, session_id='integration', turn_id='turn-1', **extra)
            result = subprocess.run([sys.executable, hook], input=json.dumps(payload), text=True,
                                    capture_output=True, timeout=3,
                                    env={**os.environ, 'XDG_RUNTIME_DIR': str(self.root)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.store.snapshot()['state'], state)


if __name__ == '__main__':
    unittest.main()
