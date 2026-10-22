"""Restart recovery must reacquire evidence, not replay old activity labels."""
from contextlib import closing
import json
from pathlib import Path
import socket
import struct
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from service.codex_daemon import DaemonRequests
from service.codex_desktop import DesktopRequests, read_frame
from service.hub import Store
from service.interactions import InteractionBroker
from service.macos import MacSource
from service.native_attention import PendingDecisions


SESSION, TURN = 'restart-session', 'original-turn'


def eventually(predicate):
    deadline = time.monotonic() + 4
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError('native recovery did not finish')
        time.sleep(.01)


class MacRestartTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.store = Store(self.root / 'hub.sqlite3')

    def source(self, **options):
        return MacSource(self.store, socket_path=self.root / 'hooks.sock',
            allowance_reader=lambda: None, turn_status_reader=lambda _: {},
            turn_metadata_reader=options.pop('turn_metadata_reader', lambda _: {}),
            title_reader=lambda _: {}, **options)

    def hook(self, source, event='working', turn=TURN, **extra):
        return source.receive(dict(command='agent-event', session=SESSION, turn=turn,
            event=event, workspaceLabel='paceman', **extra))

    def seed(self, event='working'):
        with self.source() as source:
            self.hook(source, event)

    def owner(self, source, status='inProgress', turn=TURN, pending=False):
        source.native_requests_changed(SESSION, PendingDecisions('owner',
            frozenset({(turn, 'int', '1')}) if pending else frozenset(),
            known_turns=frozenset({turn}), turn_states=frozenset({(turn, status)})))

    def test_working_requires_live_owner_and_survives_another_restart_while_unavailable(self):
        self.seed()
        for _ in range(2):
            with self.source() as source:
                self.assertEqual(source.native_response_sessions(), {SESSION: TURN})
                self.assertEqual(self.store.snapshot()['sessions'], [])
                source.native_requests_changed(SESSION, None)
                source.native_requests_changed(SESSION, PendingDecisions('owner', frozenset()))
                source._recover_turns([], dict(source.recovering_sessions))
                self.assertEqual(self.store.snapshot()['sessions'], [])
        with self.source() as source:
            self.owner(source)
            self.assertEqual(self.store.snapshot()['state'], 'working')
            self.assertEqual(self.store.snapshot()['sessions'][0]['workspaceLabel'], 'paceman')

    def test_restart_during_attention_debounce_retains_lookup_identity(self):
        with self.source() as source:
            self.hook(source, 'needs-input', hook='PermissionRequest')
            self.assertEqual(self.store.snapshot()['sessions'], [])
        with self.source() as source:
            self.assertEqual(source.native_response_sessions(), {SESSION: TURN})
            self.owner(source, pending=True)
            self.assertEqual(self.store.snapshot()['state'], 'needs_input')

    def test_recovered_activity_preserves_direct_codex_session_link(self):
        session = '01a15fac-3987-72a0-aebc-48995026e622'
        with self.source() as source:
            source.receive(dict(command='agent-event', session=session, turn=TURN, event='working'))
        with self.source() as source:
            source.native_requests_changed(session, PendingDecisions('owner', frozenset(),
                known_turns=frozenset({TURN}), turn_states=frozenset({(TURN, 'inProgress')})))
            self.assertEqual(self.store.snapshot()['sessions'][0]['threadID'], session)

    def test_finished_failed_and_closed_do_not_reappear_as_working(self):
        for outcome, expected in [('completed', 'finished'), ('failed', 'failed'), ('interrupted', 'idle')]:
            with self.subTest(outcome=outcome):
                self.seed()
                with self.source() as source:
                    self.owner(source, outcome)
                    self.assertEqual(self.store.snapshot()['state'], expected)
                    self.assertFalse(source.recovering_sessions)
                    self.hook(source, 'ended')
        with self.source() as source:
            self.assertEqual(source.native_sessions(), [])
            self.owner(source, pending=True)
            self.assertEqual(self.store.snapshot()['state'], 'idle')

    def test_completed_plan_restores_attention_then_its_original_outcome(self):
        self.seed('completed')
        with self.source() as source:
            self.owner(source, 'completed', pending=True)
            self.assertEqual(self.store.snapshot()['state'], 'needs_input')
            self.owner(source, 'completed')
            self.assertEqual(self.store.snapshot()['state'], 'finished')

    def test_old_completed_plan_keeps_recovery_binding_until_owner_reconnects(self):
        self.seed('completed')
        rows = {SESSION: [dict(id=TURN, status='completed')]}
        with self.source(turn_metadata_reader=lambda _: rows) as source:
            with patch('service.macos.time.time', return_value=time.time() + 3600):
                source._recover_turns([], dict(source.recovering_sessions))
                source.tick()
                self.assertEqual(source.native_response_sessions(), {SESSION: TURN})
                self.assertEqual(self.store.snapshot()['sessions'], [])
                self.owner(source, 'completed', pending=True)
                self.assertEqual(self.store.snapshot()['state'], 'needs_input')
                self.owner(source, 'completed')
                self.assertEqual(self.store.snapshot()['state'], 'finished')

    def test_private_recovery_records_are_bounded_and_provider_disable_clears_them(self):
        with self.source() as source:
            for index in range(130):
                source.receive(dict(command='agent-event', session=f'session-{index}', turn='turn', event='working'))
            with self.store.connect() as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM mac_codex_tracking').fetchone()[0], 128)
            public = json.dumps(self.store.snapshot())
            self.assertNotIn('session-0', public)
        with self.source(providers=('claude',)) as source:
            self.assertEqual(source.native_sessions(), [])
            with self.store.connect() as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM mac_codex_tracking').fetchone()[0], 0)

    def test_old_result_without_pending_decision_stays_history_without_new_alert(self):
        self.seed('completed')
        with patch('service.macos.time.time', return_value=time.time() + 3600):
            with self.source() as source:
                before = self.store.snapshot()
                self.owner(source, 'completed')
                after = self.store.snapshot()
                self.assertEqual(after['sessions'], [])
                self.assertEqual(after['eventID'], before['eventID'])
                self.assertEqual(after['completedSessions'], before['completedSessions'])
                self.assertEqual(source.native_sessions(), [])

    def test_saved_interrupted_is_unknown_but_confirmed_results_recover_without_owner(self):
        self.seed()
        rows = {SESSION: [dict(id=TURN, status='interrupted')]}
        with self.source(turn_metadata_reader=lambda _: rows) as source:
            source._recover_turns([], dict(source.recovering_sessions))
            self.assertEqual(self.store.snapshot()['sessions'], [])
            rows[SESSION][0]['status'] = 'completed'
            source._recover_turns([], dict(source.recovering_sessions))
            self.assertEqual(self.store.snapshot()['state'], 'finished')

    def test_newer_native_turn_supersedes_saved_turn_without_new_hook(self):
        self.seed()
        with self.source() as source:
            self.owner(source, turn='new-turn', pending=True)
            self.assertEqual(source.native_response_sessions(), {SESSION: 'new-turn'})
            self.assertEqual(self.store.snapshot()['state'], 'needs_input')

    def test_saved_order_selects_newer_turn_without_claiming_it_is_working(self):
        self.seed()
        rows = {SESSION: [dict(id='new-turn', status='interrupted'), dict(id=TURN, status='completed')]}
        with self.source(turn_metadata_reader=lambda _: rows) as source:
            source._recover_turns([], dict(source.recovering_sessions))
            self.assertEqual(source.native_response_sessions(), {SESSION: 'new-turn'})
            self.assertEqual(self.store.snapshot()['sessions'], [])
            self.owner(source, turn='new-turn')
            self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_hooks_supersede_inflight_recovery_and_old_turns_stay_rejected(self):
        for change in ('prompt', 'end', 'disable'):
            with self.subTest(change=change):
                self.seed()
                with self.source() as source:
                    def read(_):
                        if change == 'prompt':
                            self.hook(source, turn='new-turn', hook='UserPromptSubmit')
                        elif change == 'end':
                            self.hook(source, 'ended')
                        else:
                            source.settings_reader = lambda: ['claude']
                            source._apply_settings()
                        return {SESSION: [dict(id=TURN, status='failed')]}
                    source.turn_metadata_reader = read
                    source._recover_turns([], dict(source.recovering_sessions))
                    self.assertFalse(source.recovering_sessions)
                    self.assertEqual(self.store.snapshot()['state'], 'working' if change == 'prompt' else 'idle')
                    if change == 'prompt':
                        self.hook(source, 'needs-input', hook='PermissionRequest')
                        source.turn_metadata_reader = lambda _: {SESSION: [dict(id='new-turn', status='interrupted'),
                                                                          dict(id=TURN, status='completed')]}
                        source._recover_turns(list(source.pending_turn_events.items()))
                        self.assertFalse(source.pending_attention)
                    self.hook(source, 'ended')

    def test_new_turn_hook_during_recovery_checks_saved_order_before_replaying(self):
        self.seed()
        rows = {SESSION: [dict(id='new-turn', status='interrupted'), dict(id=TURN, status='completed')]}
        with self.source(turn_metadata_reader=lambda _: rows) as source:
            self.hook(source, 'needs-input', turn='new-turn', hook='PermissionRequest')
            self.assertEqual(self.store.snapshot()['sessions'], [])
            source._recover_turns(list(source.pending_turn_events.items()), dict(source.recovering_sessions))
            self.assertEqual(source.native_response_sessions(), {SESSION: 'new-turn'})
            self.assertTrue(source.pending_attention)
            self.assertFalse(source.recovering_sessions)

    def test_daemon_replay_confirms_working_and_waiting_after_restart(self):
        self.seed()
        with self.source() as source, closing(InteractionBroker()) as broker:
            adapter = DaemonRequests(broker, source.native_response_sessions, attention=source.native_requests_changed)
            self.addCleanup(adapter._reset)
            adapter.joined[SESSION] = TURN
            adapter.items[SESSION] = {}
            adapter.ready.add(SESSION)
            adapter.turn_states[SESSION] = (TURN, 'inProgress')
            adapter._sync(SESSION)
            self.assertEqual(self.store.snapshot()['state'], 'working')
            adapter.receive(dict(method='thread/status/changed', params=dict(threadId=SESSION,
                status=dict(type='active', activeFlags=['waitingOnApproval']))))
            self.assertEqual(self.store.snapshot()['state'], 'needs_input')

    def test_desktop_transport_reconnect_replays_approval_and_finishes_without_new_hooks(self):
        native = self.root / 'native.sock'
        listener = self.enterContext(closing(socket.socket(socket.AF_UNIX)))
        listener.bind(str(native))
        listener.listen()
        listener.settimeout(.1)
        stop, errors = threading.Event(), []
        sensitive = 'private approval command must stay in RAM'
        raw = dict(id=7, method='item/commandExecution/requestApproval', params=dict(
            threadId=SESSION, turnId=TURN, itemId='command', command=sensitive,
            availableDecisions=['accept', 'cancel']))

        def send(connection, message):
            data = json.dumps(message).encode()
            connection.sendall(struct.pack('<I', len(data)) + data)

        def snapshot(connection, pending):
            send(connection, dict(type='broadcast', sourceClientId='native-owner', version=11,
                method='thread-stream-state-changed', params=dict(hostId='local', conversationId=SESSION,
                change=dict(type='snapshot', revision=1 if pending else 2, conversationState=dict(id=SESSION,
                    requests=[raw] if pending else [], turns=[dict(turnId=TURN,
                        status='inProgress' if pending else 'completed', items=[])])))))

        def run_owner():
            while not stop.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                try:
                    with connection:
                        while not stop.is_set():
                            message = read_frame(connection)
                            method = message.get('method')
                            if method == 'thread-stream-following-changed':
                                if message['params']['following']:
                                    snapshot(connection, True)
                                continue
                            reply = dict(type='response', requestId=message['requestId'], resultType='success', result={})
                            if method == 'initialize':
                                reply['result'] = dict(clientId='paceman-test')
                            elif method == 'thread-owner-discovery':
                                reply['handledByClientId'] = 'native-owner'
                            elif method == 'thread-follower-command-approval-decision':
                                self.assertEqual(message['params']['requestId'], 7)
                            send(connection, reply)
                            if method == 'thread-follower-command-approval-decision':
                                snapshot(connection, False)
                except (EOFError, ConnectionResetError, BrokenPipeError):
                    pass
                except Exception as error:
                    errors.append(error)

        thread = threading.Thread(target=run_owner, daemon=True)
        thread.start()
        try:
            for restart in (False, True):
                with self.source() as source, closing(InteractionBroker()) as broker:
                    if not restart:
                        self.hook(source)
                    with DesktopRequests(broker, source.native_sessions, path=native,
                                         attention=source.native_requests_changed):
                        eventually(lambda: self.store.snapshot()['state'] == 'needs_input' and broker.pending()['requests'])
                        with self.store.connect() as db:
                            self.assertNotIn(sensitive, '\n'.join(db.iterdump()))
                        if restart:
                            request = broker.pending()['requests'][0]
                            broker.submit(dict(generation=broker.generation, requestID=request['requestID'], version=1,
                                idempotencyKey='after-restart', action='choose', optionID='decision-0'))
                            # Native completion must restore the result, rather than
                            # requiring another lifecycle hook from the agent.
                            eventually(lambda: not broker.pending()['awaitingRequestIDs'])
                            eventually(lambda: self.store.snapshot()['state'] == 'finished')
            self.assertEqual(errors, [])
        finally:
            stop.set()
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
