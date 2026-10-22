"""Linux source integration with the shared, nonblocking native responders."""
import datetime as dt
import hashlib
import http.client
import json
import os
import sys
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from service.claude_hooks import message_for
from service.claude_remote import NativeRequests
from service.codex_daemon import DaemonRequests
from service.hub import Store
from service import hub
from service.interactions import InteractionBroker
from service.linux_native import claude_token
from service.omarchy import OmarchySource
from service.processes import AgentProcesses, ProcessIdentity
from service.push import Result, Worker
from service.relay import valid_payload
from tests.identity import device


class LinuxSourceParityTests(unittest.TestCase):
    def setUp(self):
        self.temp = self.enterContext(tempfile.TemporaryDirectory())
        self.root = Path(self.temp)
        self.store = Store(self.root / 'hub.sqlite3')
        self.owner = ProcessIdentity(100, '1', 'boot')
        self.processes = Mock(spec=AgentProcesses)
        self.processes.identify.side_effect = lambda *_a, **_kw: self.owner
        self.processes.is_alive.side_effect = lambda owner: owner == self.owner
        self.clock = 100.0
        self.enabled = ['codex', 'claude']
        self.source = self.enterContext(OmarchySource(self.store, allowance_reader=lambda: [], socket_path=self.root / 'hook.sock',
            state_dir=self.root, processes=self.processes, monotonic=lambda: self.clock,
            providers=self.enabled, settings_reader=lambda: self.enabled,
            title_reader=lambda _refs: {}, turn_metadata_reader=lambda _sessions: {}))
        self.broker = InteractionBroker()
        self.addCleanup(self.broker.close)

    def codex(self, event='working', turn='turn', **fields):
        self.source.receive(dict(command='agent-event', source='codex', adapter='paceman',
            session='session', turn=turn, event=event, **fields), peer_pid=100)
        return self.store.snapshot()

    def claude(self, hook, turn='turn', **fields):
        with patch.dict(os.environ, {'CLAUDE_CODE_BRIDGE_SESSION_ID': 'session_remote'}):
            command = message_for(dict(hook_event_name=hook, session_id='claude-session',
                prompt_id=turn, **fields))
        self.source.receive(command, peer_pid=100)
        return self.store.snapshot()

    def restart(self):
        self.source.__exit__(None, None, None)
        self.source.__enter__()

    def recover(self, result):
        self.source.turn_metadata_reader = lambda _sessions: result
        self.source.next_recovery_at = 0
        self.source.tick(force=True)
        if self.source.recovery_thread:
            self.source.recovery_thread.join(2)
            self.assertFalse(self.source.recovery_thread.is_alive())
        return self.store.snapshot()

    def daemon(self):
        adapter = DaemonRequests(self.broker, self.source.native_response_sessions,
            attention=self.source.native_requests_changed)
        adapter.connection = Mock()
        adapter.joined['session'] = 'turn'
        adapter.ready.add('session')
        adapter.items['session'] = {}
        self.addCleanup(adapter._reset)
        return adapter

    @staticmethod
    def approval(rid):
        return dict(id=rid, method='item/commandExecution/requestApproval', params=dict(
            threadId='session', turnId='turn', itemId='item', command='echo fixture',
            availableDecisions=['accept', 'cancel']))

    def test_restart_preserves_question_deadline_native_binding_and_legacy_precedence(self):
        self.codex(hook='UserPromptSubmit')
        self.codex('needs-input', attention='async', hook='PreToolUse')
        self.clock += 3
        self.restart()
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.assertEqual(self.source.native_response_sessions(), {'session': 'turn'})
        self.clock += 3
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.source.receive(dict(command='agent-event', source='codex', session='session', turn='turn',
            event='working', hook='UserPromptSubmit'), peer_pid=100)
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.assertEqual(self.codex('completed')['state'], 'finished')
        self.assertEqual(self.source.native_response_sessions(), {'session': 'turn'})

    def test_restart_and_pid_reuse_cannot_restore_old_question_or_response_binding(self):
        self.codex(hook='UserPromptSubmit')
        self.codex('needs-input', attention='async')
        self.owner = ProcessIdentity(100, '2', 'new-boot')
        self.restart()
        self.assertEqual(self.store.snapshot()['sessions'], [])
        self.assertEqual(self.source.native_response_sessions(), {})
        self.assertFalse(self.source.pending_questions)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM omarchy_tracking').fetchone()[0], 0)

    def test_native_wait_survives_unrelated_events_disconnect_and_restart_but_not_new_turn(self):
        self.codex(hook='UserPromptSubmit')
        self.source.native_requests_changed('session', {'turn': True})
        self.codex(hook='UserPromptSubmit')
        self.source.native_requests_changed('session', None)
        self.restart()
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.codex(turn='next', hook='UserPromptSubmit')
        self.source.native_requests_changed('session', {'turn': True})
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.enabled = []
        self.source.tick(force=True)
        self.source.native_requests_changed('session', {'next': True})
        self.assertEqual(self.store.snapshot()['sessions'], [])
        self.assertEqual(self.source.session_refs, {})

    def test_native_codex_response_preserves_sibling_attention_and_exact_wire_request(self):
        self.codex(hook='UserPromptSubmit')
        adapter = self.daemon()
        adapter.receive(self.approval(1))
        adapter.receive(self.approval(2))
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        first = self.broker.pending()['requests'][0]
        self.broker.submit(dict(generation=self.broker.generation, requestID=first['requestID'],
            version=1, idempotencyKey='approval', action='choose', optionID='decision-0'))
        deadline = time.monotonic() + 2
        while not adapter.connection.send.called and time.monotonic() < deadline:
            time.sleep(.005)
        adapter.connection.send.assert_called_once_with(dict(id=1, result=dict(decision='accept')))
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        adapter.receive(dict(method='serverRequest/resolved', params=dict(threadId='session', requestId=1)))
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        adapter.receive(dict(method='serverRequest/resolved', params=dict(threadId='session', requestId=2)))
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_native_codex_question_uses_shared_answer_contract(self):
        self.codex(hook='UserPromptSubmit')
        adapter = self.daemon()
        adapter.receive(dict(id='question', method='item/tool/requestUserInput', params=dict(
            threadId='session', turnId='turn', questions=[dict(id='q', question='Which?',
                isSecret=False, isOther=True, options=[dict(label='Small', description='')])])) )
        question = self.broker.pending()['requests'][0]
        self.assertEqual(question['sessionID'], hashlib.sha256(b'codex:session').hexdigest())
        self.broker.submit(dict(generation=self.broker.generation, requestID=question['requestID'],
            version=1, idempotencyKey='question', action='answer', answers={'q': {'selected': [0], 'text': ''}}))
        deadline = time.monotonic() + 2
        while not adapter.connection.send.called and time.monotonic() < deadline:
            time.sleep(.005)
        adapter.connection.send.assert_called_once_with(dict(id='question', result=dict(answers={'q': {'answers': ['Small']}})))
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')

    def test_linux_startup_advertises_authenticated_interactions_and_starts_native_followers(self):
        root = self.root / 'startup'
        store = Store(root / 'hub.sqlite3')
        paired = store.redeem(store.invite('https://fixture.test')['invitation'], device=device())
        def verify(server, **_kwargs):
            self.assertIsNotNone(server.interactions)
            server.daemon_threads = False
            for route in ('/v1/snapshot', '/v1/interactions'):
                receiver = threading.Thread(target=server.handle_request, daemon=True)
                receiver.start()
                connection = http.client.HTTPConnection(*server.server_address, timeout=2)
                try:
                    connection.request('GET', route, headers={'Authorization': 'Bearer ' + paired['credential']})
                    reply = connection.getresponse()
                    self.assertEqual(reply.status, 200)
                    value = json.loads(reply.read())
                    self.assertTrue(value['interactionsEnabled'] if route.endswith('snapshot') else
                                    value['requests'] == [])
                finally:
                    connection.close()
                    receiver.join(2)
                self.assertFalse(receiver.is_alive())
        with patch.object(sys, 'argv', ['paceman-source', '--data-dir', str(root), 'serve',
                '--source', 'omarchy', '--agent-socket', str(root / 'agent.sock'), '--port', '0']), \
                patch.object(hub.Server, 'serve_forever', autospec=True, side_effect=verify), \
                patch('service.codex_daemon.DaemonRequests', autospec=True) as daemon, \
                patch('service.claude_remote.RemoteRequests', autospec=True) as remote, \
                patch('service.codex_desktop.DesktopRequests', autospec=True) as desktop, \
                patch('service.interactions.ResponseListener', autospec=True) as listener, \
                patch('builtins.print'):
            hub.main()
        daemon.assert_called_once()
        remote.assert_called_once()
        desktop.assert_not_called()
        listener.assert_not_called()
        self.assertFalse((root / 'agent.sock').exists())

    def test_saved_terminal_outcomes_recover_missed_stop_and_ignore_interrupted(self):
        self.codex(hook='UserPromptSubmit')
        self.assertEqual(self.recover({'session': [{'id': 'turn', 'status': 'interrupted'}]})['state'], 'working')
        self.assertEqual(self.recover({'session': [{'id': 'turn', 'status': 'completed'}]})['state'], 'finished')
        self.codex(turn='failed-turn', hook='UserPromptSubmit')
        self.assertEqual(self.recover({'session': [{'id': 'failed-turn', 'status': 'failed'}]})['state'], 'failed')
        self.assertEqual(self.source.native_response_sessions(), {'session': 'failed-turn'})
        self.assertEqual(self.codex('needs-input', turn='failed-turn')['state'], 'failed')
        self.assertEqual(self.codex('completed', turn='failed-turn')['state'], 'failed')
        self.assertEqual(self.codex('ended', turn='failed-turn')['state'], 'failed')
        self.assertEqual(self.source.native_response_sessions(), {}, 'A retained result has no live response binding')

    def test_missing_prompt_recovery_uses_latest_saved_turn_and_replays_only_matching_hooks(self):
        self.codex(hook='UserPromptSubmit')
        self.codex('completed')
        self.codex('needs-input', turn='new', hook='PermissionRequest')
        self.assertEqual(self.store.snapshot()['state'], 'finished')
        self.assertEqual(self.recover({'session': [{'id': 'turn', 'status': 'completed'}]})['state'], 'finished')
        self.assertEqual(self.recover({'session': [{'id': 'new', 'status': 'inProgress'},
            {'id': 'turn', 'status': 'completed'}]})['state'], 'needs_input')
        self.assertEqual(self.source.native_response_sessions(), {'session': 'new'})

    def test_saved_failure_corrects_stop_and_known_historical_hooks_are_retired(self):
        self.codex(hook='UserPromptSubmit')
        self.codex('completed')
        self.assertEqual(self.recover({'session': [{'id': 'turn', 'status': 'failed'}]})['state'], 'failed')
        self.codex(turn='new', hook='UserPromptSubmit')
        self.codex('needs-input', turn='turn', hook='PermissionRequest')
        self.recover({'session': [{'id': 'new', 'status': 'inProgress'}, {'id': 'turn', 'status': 'failed'}]})
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.assertFalse(self.source.pending_turn_events)

    def test_delayed_saved_outcome_cannot_finish_a_new_prompt_or_replace_process_owner(self):
        self.codex(hook='UserPromptSubmit')
        started, done = threading.Event(), threading.Event()
        def reader(_sessions):
            started.set()
            done.wait(2)
            return {'session': [{'id': 'turn', 'status': 'completed'}]}
        self.source.turn_metadata_reader = reader
        self.source.tick(force=True)
        self.assertTrue(started.wait(1))
        self.codex(turn='next', hook='UserPromptSubmit')
        done.set()
        self.source.recovery_thread.join(2)
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.assertEqual(self.source.native_response_sessions(), {'session': 'next'})

    def test_recovery_preserves_newer_turn_hook_received_during_metadata_read(self):
        self.codex(hook='UserPromptSubmit')
        self.codex('needs-input', turn='resumed', hook='PermissionRequest')
        started, done = threading.Event(), threading.Event()
        self.addCleanup(done.set)
        def reader(_sessions):
            started.set()
            if not done.wait(2):
                raise TimeoutError('metadata fixture was not released')
            return {'session': [{'id': 'resumed', 'status': 'completed'},
                                {'id': 'turn', 'status': 'completed'}]}
        self.source.turn_metadata_reader = reader
        self.source.next_recovery_at = 0
        self.source.tick(force=True)
        self.assertTrue(started.wait(1))
        self.codex('needs-input', turn='newest', hook='PermissionRequest')
        done.set()
        self.source.recovery_thread.join(2)
        self.assertFalse(self.source.recovery_thread.is_alive())
        key = hashlib.sha256(b'codex:session').hexdigest()
        self.assertIn(key, self.source.pending_turn_events)
        pending = self.source.pending_turn_events[key]
        self.assertEqual(pending['previous'], 'resumed')
        self.assertEqual([event['turn'] for event in pending['events']], ['newest'])
        self.assertEqual(self.source.next_recovery_at, 0)
        current = self.recover({'session': [{'id': 'newest', 'status': 'inProgress'},
            {'id': 'resumed', 'status': 'completed'}, {'id': 'turn', 'status': 'completed'}]})
        self.assertEqual(current['state'], 'needs_input')
        self.assertEqual(self.source.native_response_sessions(), {'session': 'newest'})
        self.assertFalse(self.source.pending_turn_events)

    def test_replacement_codex_owner_cannot_inherit_attention_or_pending_recovery(self):
        self.codex(hook='UserPromptSubmit')
        self.source.native_requests_changed('session', {'turn': True})
        self.codex('needs-input', turn='unknown', hook='PermissionRequest')
        key = hashlib.sha256(b'codex:session').hexdigest()
        self.assertIn(key, self.source.pending_turn_events)
        self.owner = ProcessIdentity(100, '2', 'boot')
        current = self.codex(hook='UserPromptSubmit')
        self.assertEqual(current['state'], 'working')
        self.assertNotIn(key, self.source.native_attention)
        self.assertNotIn(key, self.source.pending_turn_events)
        with self.store.connect() as db:
            tracking = db.execute('SELECT * FROM omarchy_tracking WHERE id=?', (key,)).fetchone()
            self.assertIsNone(tracking['attention_turn'])
            self.assertIsNone(tracking['waiting'])
        self.restart()
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_replacement_owner_clears_previous_confirmed_turn(self):
        self.codex(hook='UserPromptSubmit')
        self.recover({'session': [{'id': 'turn', 'status': 'completed'}]})
        self.assertTrue(self.source.confirmed_turns)
        self.owner = ProcessIdentity(100, '2', 'boot')
        self.codex(hook='UserPromptSubmit')
        self.assertFalse(self.source.confirmed_turns)

    def test_replacement_claude_owner_cannot_inherit_native_attention(self):
        self.claude('UserPromptSubmit')
        key = self.source.native_claude_sessions()[0][0]
        self.source.native_claude_requests_changed(key, 'turn', True)
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.owner = ProcessIdentity(100, '2', 'boot')
        current = self.claude('UserPromptSubmit')
        self.assertEqual(current['state'], 'working')
        self.assertNotIn(key, self.source.native_attention)
        self.restart()
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_native_claude_rejoin_resolves_hook_wait_without_hiding_parallel_native_request(self):
        self.claude('UserPromptSubmit')
        self.claude('PreToolUse', tool_name='AskUserQuestion', tool_use_id='ask')
        session = self.source.native_claude_sessions()[0][0]
        sent = []
        adapter = NativeRequests(self.broker, session, 'session_remote', sent.append,
            attention=lambda value: self.source.native_claude_requests_changed(session, 'turn', value),
            resolved=lambda tools, pending: self.source.native_claude_requests_resolved(session, 'turn', tools, pending))
        self.addCleanup(adapter.close)
        def permission(rid, tool, tool_id, inputs):
            return dict(type='control_request', session_id='session_remote', request_id=rid,
                request=dict(subtype='can_use_tool', tool_name=tool, tool_use_id=tool_id, input=inputs))
        requests = [permission('ask', 'AskUserQuestion', 'ask', {'questions': [dict(question='Which?',
            header='Choice', multiSelect=False, options=[dict(label='Small', description='')])]}),
            permission('parallel', 'Bash', 'bash', {'command': 'echo fixture'})]
        adapter.initialize()
        def receive(frame, seq):
            adapter.receive('client_event', dict(sequence_num=seq, source='worker', payload=frame))
        receive(dict(type='control_response', session_id='session_remote', response=dict(subtype='success',
            request_id=sent[-1]['request_id'], pending_permission_requests=requests,
            pending_user_dialog_requests=[])), 1)
        self.assertEqual(len(self.broker.pending()['requests']), 2)
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        for seq, rid in enumerate(('ask', 'parallel'), 2):
            receive(dict(type='control_response', session_id='session_remote', response=dict(
                subtype='success', request_id=rid, response={})), seq)
        self.clock += 6
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.restart()
        self.assertEqual(self.source.native_claude_sessions(), [(session, 'session_remote', 'turn')])
        self.claude('UserPromptSubmit', turn='new')
        self.source.native_claude_requests_changed(session, 'turn', True)
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_both_quota_windows_reach_direct_watch_without_new_activity_alert(self):
        now = int(time.time())
        stamp = lambda value: dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat()
        path = self.root / 'agents/usage/codex.json'
        path.parent.mkdir(parents=True)
        before = self.codex(hook='UserPromptSubmit')
        path.write_text(json.dumps(dict(schemaVersion=1, id='codex', updatedAt=stamp(now), limits=[
            dict(label='5h window', percent=.7, resetsAt=stamp(now+3600)),
            dict(label='Weekly (7-day)', percent=.2, resetsAt=stamp(now+86400))])))
        self.source.tick(force=True)
        current = self.store.snapshot()
        self.assertEqual(current['eventID'], before['eventID'])
        self.assertEqual({r['windowDurationMins'] for r in current['allowances']}, {300, 10080})
        paired = self.store.redeem(self.store.invite('https://fixture.test')['invitation'], device=device())
        self.store.watch_push_device(paired['credential'], dict(deviceToken='ab'*32,
            environment='development', usageSchema=2, selectionRevision=1))
        sender = Mock()
        sender.send.return_value = Result(200, 'Accepted', 'fixture')
        worker = Worker(self.store, sender, self.root / 'push.jsonl')
        worker.step_watch_allowance(now, current)
        payload = sender.send.call_args.args[1]
        self.assertTrue(valid_payload('watch', current['sourceID'], payload))
        self.assertCountEqual(payload['allowances'], current['allowances'])
        path.unlink()
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['allowances'], current['allowances'])
        self.enabled = ['claude']
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['allowances'], [])


class LinuxCredentialTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(patch.dict(os.environ, {'CLAUDE_CONFIG_DIR': str(self.root)}))
        self.path = self.root / '.credentials.json'
        self.value = dict(claudeAiOauth=dict(accessToken='fixture-token', scopes=['user:sessions:claude_code']))
        self.write()

    def write(self):
        self.path.write_text(json.dumps(self.value))
        self.path.chmod(0o600)

    def test_reads_existing_scoped_login_without_mutation(self):
        before = self.path.read_bytes()
        self.assertEqual(claude_token(), 'fixture-token')
        self.assertEqual(self.path.read_bytes(), before)

    def test_rejects_public_symlinked_oversized_or_unscoped_login(self):
        self.path.chmod(0o644)
        with self.assertRaises(OSError):
            claude_token()
        self.path.unlink()
        target = self.root / 'other'
        target.write_text(json.dumps(self.value))
        self.path.symlink_to(target)
        with self.assertRaises(OSError):
            claude_token()
        self.path.unlink()
        self.value['claudeAiOauth']['scopes'] = []
        self.write()
        with self.assertRaises(ValueError):
            claude_token()
        self.path.write_bytes(b' ' * 65537)
        with self.assertRaises(ValueError):
            claude_token()
