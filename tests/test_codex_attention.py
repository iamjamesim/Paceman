"""Verified stream-v11 human inputs and native-only decision lifetime.

Fixtures model the inspected 26.1013.40934 producer. Coexisting plan/question
requests are an accepted protocol fixture, not a claim of live reproduction.
"""
from contextlib import closing
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from service.codex_attention import PendingDecisions, human_request, HUMAN_METHODS, INTERNAL_METHODS, HUMAN_DYNAMIC_TOOLS
from service.codex_desktop import DesktopRequests
from service.diagnostics import DeliveryDiagnostics
from service.hub import Store
from service.interactions import InteractionBroker
from service.macos import MacSource, FINISHED_RETENTION
from tests.test_codex_desktop import SESSION, browser, command, snapshot, submission, wait_until


def dynamic(tool, arguments, **params):
    return dict(id=tool, method='item/tool/call', params=dict(threadId=SESSION, turnId='turn',
        tool=tool, arguments=arguments, **params))


def human_inputs():
    return [
        *(dynamic('request_environment_input', {'mode': mode})
          for mode in ('repositories', 'name', 'secrets', 'network', 'review')),
        dynamic('request_onboarding_input', {'questions': [dict(id='q', question='Which?',
            options=[dict(label='First'), dict(label='Second')])]}),
        dynamic('request_option_picker', dict(question='Choose', options=[dict(label='First')])),
        dynamic('setup_codex_step', {'step': 'role'}),
        dynamic('setup_codex_step', {'step': 'task'}),
    ]


class HumanRequestTests(unittest.TestCase):
    def test_verified_dynamic_inputs_have_attention_but_no_invented_reply(self):
        with closing(InteractionBroker()) as broker:
            attention = []
            adapter = DesktopRequests(broker, lambda: [SESSION], attention=lambda _, p: attention.append(p))
            adapter.owners[SESSION] = 'native-owner'
            self.addCleanup(adapter._reset)
            for raw in human_inputs():
                for namespace in ('absent', None, 'codex_app'):
                    with self.subTest(tool=raw['params']['tool'], namespace=namespace):
                        if namespace == 'absent':
                            raw['params'].pop('namespace', None)
                        else:
                            raw['params']['namespace'] = namespace
                        self.assertTrue(human_request(SESSION, raw))
                        adapter._receive(snapshot([raw]))
                        self.assertEqual(len(attention[-1].for_turn('turn')), 1)
                        self.assertEqual(broker.pending()['requests'], [])
                        self.assertEqual(broker.pending()['awaitingRequestIDs'], [])

    def test_internal_execution_and_invalid_dynamic_inputs_are_not_human_prompts(self):
        invalid = [dynamic('setup_codex_step', {'step': 'complete'}),
            dynamic('setup_codex_step', {'step': 'unknown'}),
            dynamic('setup_codex_step', {'step': 'role', 'extra': True}),
            dynamic('request_environment_input', {'mode': 'unknown'}),
            dynamic('request_environment_input', {'mode': 'name', 'reason': ''}),
            dynamic('request_environment_input', {'mode': 'secrets', 'secrets': [{'name': ''}]}),
            dynamic('request_option_picker', {'question': 'Which?', 'options': 'wrong'}),
            dynamic('request_onboarding_input', {'questions': []}),
            dynamic('request_onboarding_input', {'questions': [{'id': 'a', 'question': 'Which?', 'options': []}]}),
            dynamic('request_onboarding_input', {'questions': [], 'unexpected': True}),
            dynamic('request_option_picker', None),
            dynamic('read_thread', {}), dynamic('finalize_environment', {}),
            dynamic('request_option_picker', {'question': 'Which?', 'options': []}, namespace='other'),
            dict(id='unknown', method='future/requestDecision', params=dict(threadId=SESSION, turnId='turn'))]
        for method in ('currentTime/read', 'account/chatgptAuthTokens/refresh', 'attestation/generate',
                       'item/tool/requestSetupCodexContextPicker', 'execCommandApproval', 'applyPatchApproval'):
            invalid.append(dict(id=method, method=method, params=dict(threadId=SESSION, turnId='turn')))
        with closing(InteractionBroker()) as broker:
            attention = []
            adapter = DesktopRequests(broker, lambda: [SESSION], attention=lambda _, p: attention.append(p))
            adapter.owners[SESSION] = 'native-owner'
            self.addCleanup(adapter._reset)
            for raw in invalid:
                with self.subTest(raw=raw):
                    self.assertFalse(human_request(SESSION, raw))
                    adapter._receive(snapshot([raw]))
                    self.assertEqual(attention[-1].requests, frozenset())
                    self.assertEqual(broker.pending()['requests'], [])

    def test_unknown_diagnostics_are_count_only_and_emitted_only_when_counts_change(self):
        with tempfile.TemporaryDirectory() as temporary, closing(InteractionBroker()) as broker:
            diagnostics = DeliveryDiagnostics(Path(temporary) / 'diagnostics.jsonl')
            diagnostics.record = Mock(wraps=diagnostics.record)
            broker.diagnostics = diagnostics
            attention = []
            adapter = DesktopRequests(broker, lambda: [SESSION], attention=lambda _, p: attention.append(p))
            adapter.owners[SESSION] = 'native-owner'
            self.addCleanup(adapter._reset)
            raw = dict(id='private-id', method='future/requestDecision',
                params=dict(threadId=SESSION, turnId='turn', prompt='private prompt'))
            adapter._receive(snapshot([raw]))
            adapter._receive(snapshot([raw], 2))
            self.assertEqual(attention[-1].requests, frozenset(), 'Unknown is not proof of human attention')
            self.assertEqual(diagnostics.record.call_count, 1)
            content = diagnostics.path.read_text()
            self.assertIn('"unknownCount":1', content)
            for value in ('private-id', 'future/requestDecision', SESSION, 'private prompt'):
                self.assertNotIn(value, content)
            adapter._receive(snapshot([], 3))
            self.assertEqual(diagnostics.record.call_count, 2)

    def test_native_only_exclusions_keep_attention_without_a_response_card(self):
        requests = [dict(id=1, method=method, params=dict(threadId=SESSION, turnId='turn'))
            for method in ('item/permissions/requestApproval', 'item/tool/requestOptionPicker',
                           'item/plan/requestImplementation', 'item/fileChange/requestApproval')]
        for marker in ('plan_token', 'confirmation_summary'):
            raw = browser(); raw['params']['_meta']['tool_params'][marker] = 'bound-native-context'
            requests.append(raw)
        raw = browser(); raw['params']['_meta']['tool_name'] = 'access_browser_origin_with_raw_cdp'
        requests.append(raw)
        raw = browser(); raw['params']['_meta']['persist'] = ['account']
        requests.append(raw)
        for tool in ('sites.execute_database_delete', 'sites.execute_database_insert', 'sites.execute_database_update'):
            raw = browser()
            raw['params']['_meta'].update(connector_id='connector_20205bf7d4e99a89d7154bb849718324',
                                         tool_name=tool, tool_params={})
            requests.append(raw)
        for mode in ('form', 'url', 'openai/userVerification', 'openai/form', 'openaiForm'):
            requests.append(dict(id=mode, method='mcpServer/elicitation/request',
                params=dict(threadId=SESSION, mode=mode, message='Native form', requestedSchema={
                    'type': 'object', 'properties': {'secret': {'type': 'string'}}})))
        requests.append(dict(id='secret', method='item/tool/requestUserInput',
            params=dict(threadId=SESSION, turnId='turn', questions=[dict(id='secret', question='Secret?',
                isSecret=True, isOther=True)])))
        raw = command(); raw['params']['availableDecisions'] = [{'unrecognizedScope': {}}]
        requests.append(raw)
        raw = command(); raw['params']['kind'] = 'unknown-terminal-input'
        requests.append(raw)
        raw = command(); raw['params']['command'] = 'x' * 40000
        requests.append(raw)
        with closing(InteractionBroker()) as broker:
            attention = []
            adapter = DesktopRequests(broker, lambda: [SESSION], attention=lambda _, p: attention.append(p))
            adapter.owners[SESSION] = 'native-owner'
            adapter.policy_loaded = True
            self.addCleanup(adapter._reset)
            for raw in requests:
                with self.subTest(method=raw['method'], params=raw['params']):
                    adapter._receive(snapshot([raw]))
                    self.assertEqual(len(attention[-1].requests), 1)
                    self.assertEqual(broker.pending()['requests'], [], 'Continue in Codex; do not narrow or guess replies')
                    self.assertEqual(broker.pending()['awaitingRequestIDs'], [])

    def test_turnless_ui_items_match_native_plan_only_rendering(self):
        from service.codex_desktop import _item_pending
        self.assertEqual(_item_pending(dict(turnId=None, status='completed', items=[dict(
            id='form', type='userInputResponse', requestId='request', completed=False)])), set())
        self.assertEqual(_item_pending(dict(turnId=None, status='completed', items=[dict(
            id='plan', type='planImplementation', isCompleted=False)])), {(None, 'plan', 'plan')})

    def test_all_recognized_methods_completed_and_foreign_session_guards(self):
        methods = ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
            'item/permissions/requestApproval', 'item/tool/requestUserInput', 'item/tool/requestOptionPicker',
            'mcpServer/elicitation/request', 'item/plan/requestImplementation']
        self.assertEqual(set(methods), HUMAN_METHODS, 'Each inventoried method needs a coverage fixture')
        self.assertEqual({raw['params']['tool'] for raw in human_inputs()}, HUMAN_DYNAMIC_TOOLS)
        self.assertEqual(INTERNAL_METHODS, frozenset({'currentTime/read', 'account/chatgptAuthTokens/refresh',
            'attestation/generate', 'item/tool/requestSetupCodexContextPicker', 'applyPatchApproval', 'execCommandApproval'}))
        for method in methods:
            raw = dict(id=1, method=method, params=dict(threadId=SESSION, turnId='turn'))
            with self.subTest(method=method):
                self.assertTrue(human_request(SESSION, raw))
                self.assertFalse(human_request('another-thread', raw))
                raw['completed'] = True
                self.assertFalse(human_request(SESSION, raw))


class NativeDecisionLifetimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        root.chmod(0o700)
        self.store = Store(root / 'hub.sqlite3')
        self.enabled = ['codex']
        self.source = MacSource(self.store, socket_path=root / 'hook.sock', providers=self.enabled,
            settings_reader=lambda: self.enabled, allowance_reader=lambda: None,
            turn_status_reader=lambda _: {}, title_reader=lambda _: {})
        self.source.__enter__()
        self.addCleanup(self.source.__exit__, None, None, None)
        self.source.next_allowance_at = self.source.next_turn_status_at = float('inf')
        self.broker = InteractionBroker()
        self.addCleanup(self.broker.close)
        self.adapter = DesktopRequests(self.broker, self.source.native_sessions,
            attention=self.source.native_requests_changed)
        self.adapter.owners[SESSION] = 'native-owner'
        self.addCleanup(self.adapter._reset)
        self.sent = []
        self.adapter._request = lambda *args, **kwargs: self.sent.append((args, kwargs))
        self.event('working', 'UserPromptSubmit')

    def event(self, event, hook, turn='turn'):
        self.source.receive(dict(command='agent-event', session=SESSION, turn=turn, event=event, hook=hook))

    def receive(self, requests, status='completed', revision=1):
        message = snapshot(requests, revision)
        message['params']['change']['conversationState']['turns'] = [dict(turnId='turn', status=status, items=[])]
        self.adapter._receive(message)

    def state(self):
        return self.store.snapshot()['state']

    def test_stop_before_or_after_native_state_and_sibling_resolution_restore_saved_outcome(self):
        plan = dict(id='plan', method='item/plan/requestImplementation',
                    params=dict(threadId=SESSION, turnId='turn'))
        question = dynamic('request_option_picker', dict(question='Which?', options=[]))
        for before in (True, False):
            for requests in ([plan, question], [question, plan]):
                with self.subTest(stop_first=before, order=[r['id'] for r in requests]):
                    self.receive([])
                    self.event('ended', 'SessionEnd')
                    self.event('working', 'UserPromptSubmit')
                    if before:
                        self.event('completed', 'Stop')
                    self.receive(requests)
                    if not before:
                        self.event('completed', 'Stop')
                    self.assertEqual(self.state(), 'needs_input')
                    self.assertEqual(self.source.native_active_sessions(), {}, 'Attention must not resume the finished turn')
                    self.assertEqual(self.broker.pending()['requests'], [], 'Use existing native continuation')
                    self.receive([question])
                    self.assertEqual(self.state(), 'needs_input', 'Resolving one sibling is insufficient')
                    self.receive([])
                    self.assertEqual(self.state(), 'finished')

    def test_turnless_mcp_retains_session_scope_across_turns_and_restores_outcome(self):
        raw = browser()
        raw['params'].pop('turnId')
        # Ordinary form entry has no safe approval codec, but is human attention.
        raw['params']['_meta'] = {}
        self.receive([raw])
        self.assertEqual(self.state(), 'needs_input')
        native = next(iter(self.source.native_attention.values()))
        self.assertEqual(native.requests, frozenset({(None, 'int', '8')}))
        self.event('completed', 'Stop')
        self.assertEqual(self.state(), 'needs_input')
        self.event('working', 'UserPromptSubmit', turn='next')
        self.assertEqual(self.state(), 'needs_input', 'Session scope is not rebound or cleared by a turn change')
        self.event('completed', 'Stop', turn='next')
        self.receive([])
        self.assertEqual(self.state(), 'finished')

    def test_pending_identity_types_completion_and_stale_turns(self):
        self.receive([command(1), command('1')], status='inProgress')
        pending = next(iter(self.source.native_attention.values()))
        self.assertEqual(len(pending.requests), 2, 'String and integer IDs are distinct')
        first = command(1); first['completed'] = True
        self.receive([first, command('1')])
        self.assertEqual(self.state(), 'needs_input')
        self.event('working', 'UserPromptSubmit', turn='next')
        self.receive([command('1')])
        self.assertEqual(self.state(), 'working', 'Old turn identities cannot reopen the new turn')
        self.event('completed', 'Stop', turn='turn')
        self.assertEqual(self.state(), 'working', 'A delayed old Stop cannot finish the current turn')

    def test_remote_acceptance_and_release_never_resolve_native_attention(self):
        self.receive([command(1), command(2)])
        first, second = self.broker.pending()['requests']
        self.broker.submit(submission(self.broker, first, action='choose', optionID='decision-0'))
        wait_until(lambda: bool(self.sent))
        self.event('completed', 'Stop')
        self.assertEqual(self.state(), 'needs_input')
        self.assertEqual(self.broker.pending()['awaitingRequestIDs'], [first['requestID']])
        self.receive([command(2)])
        self.assertEqual(self.broker.pending()['awaitingRequestIDs'], [])
        self.assertEqual(self.state(), 'needs_input', 'Submitted card lifetime is not sibling decision lifetime')
        self.broker.submit(submission(self.broker, second, action='release'))
        wait_until(lambda: not self.adapter.pending)
        self.assertEqual(len(self.sent), 1, 'Release sends no native decision')
        self.assertEqual(self.state(), 'needs_input')
        self.receive([])
        self.assertEqual(self.state(), 'finished')

    def test_supported_turnless_mcp_replies_to_its_exact_native_id(self):
        raw = browser()
        raw['params'].pop('turnId')
        raw['params']['_meta'].update(tool_name='edit_page', connector_id='pages')
        self.receive([raw])
        pending = self.broker.pending()['requests'][0]
        self.broker.submit(submission(self.broker, pending, action='choose', optionID='once'))
        wait_until(lambda: bool(self.sent))
        args, kwargs = self.sent[0]
        self.assertEqual(args[0], 'thread-follower-submit-mcp-server-elicitation-response')
        self.assertEqual(args[1], dict(conversationId=SESSION, requestId=8,
            response=dict(action='accept', content={}, _meta=None)))
        self.assertEqual(kwargs['target'], 'native-owner')
        self.event('completed', 'Stop')
        self.assertEqual(self.state(), 'needs_input')
        self.receive([])
        self.assertEqual(self.state(), 'finished')

    def test_disconnect_gap_and_stale_owner_cannot_prove_empty_or_reopen_cards(self):
        self.receive([command()])
        self.event('completed', 'Stop')
        gap = snapshot([])
        gap['params']['change'] = dict(type='patches', baseRevision=0, revision=2, patches=[])
        with self.assertRaises(ValueError):
            self.adapter._receive(gap)
        self.adapter._reset()
        self.assertEqual(self.state(), 'needs_input')
        self.assertEqual(self.broker.pending()['requests'], [])
        self.adapter.owners[SESSION] = 'replacement-owner'
        self.receive([])
        self.assertEqual(self.state(), 'needs_input', 'Old owner cannot clear pending state')
        message = snapshot([])
        message['sourceClientId'] = 'replacement-owner'
        self.adapter._receive(message)
        self.assertEqual(self.state(), 'finished', 'New owner confirms empty')
        self.receive([command()])
        self.assertEqual(self.state(), 'finished', 'Old owner cannot reopen attention')

    def test_contiguous_patches_resolve_only_matching_siblings(self):
        self.receive([command(1), command(2)])
        self.event('completed', 'Stop')
        for revision in (2, 3):
            message = snapshot([])
            message['params']['change'] = dict(type='patches', baseRevision=revision - 1,
                revision=revision, patches=[dict(op='remove', path=['requests', 0])])
            self.adapter._receive(message)
            self.assertEqual(self.state(), 'needs_input' if revision == 2 else 'finished')

    def test_ui_item_owned_decisions_survive_stop_and_resolve_by_patch(self):
        for item in (dict(id='plan', type='planImplementation', turnId='turn', isCompleted=False,
                          planContent='private plan'),
                     dict(id='form', type='userInputResponse', requestId='request', completed=False)):
            with self.subTest(item=item['type']):
                self.receive([])
                self.event('ended', 'SessionEnd')
                self.event('working', 'UserPromptSubmit')
                message = snapshot([])
                message['params']['change']['conversationState']['turns'] = [dict(
                    turnId='turn', status='completed', items=[item])]
                self.adapter._receive(message)
                self.event('completed', 'Stop')
                self.assertEqual(self.state(), 'needs_input', 'Native UI item attention survives the turn outcome')
                self.assertNotIn('private plan', json.dumps(self.adapter.states))
                field = 'isCompleted' if item['type'] == 'planImplementation' else 'completed'
                message['params']['change'] = dict(type='patches', baseRevision=1, revision=2,
                    patches=[dict(op='replace', path=['turns', 0, 'items', 0, field], value=True)])
                self.adapter._receive(message)
                self.assertEqual(self.state(), 'finished')

    def test_obsolete_reader_failure_and_discovery_cannot_replace_current_owner(self):
        self.receive([command()])
        current, old = Mock(), Mock()
        self.adapter.connection = current
        with patch('service.codex_desktop.read_frame', side_effect=EOFError):
            self.adapter._read(old)
        self.assertEqual(self.adapter.owners[SESSION], 'native-owner')
        self.assertEqual(self.state(), 'needs_input')
        self.assertEqual(len(self.broker.pending()['requests']), 1)
        self.event('ended', 'SessionEnd')
        self.adapter._request = lambda *_a, **_kw: {'handledByClientId': 'late-owner'}
        self.adapter._discover(SESSION, current)
        self.assertEqual(self.adapter.owners[SESSION], 'native-owner', 'A retired source session invalidates discovery')

    def test_disconnected_terminal_attention_does_not_expire_and_resolution_restarts_retention(self):
        self.receive([dynamic('setup_codex_step', {'step': 'role'})])
        self.event('completed', 'Stop')
        self.adapter._reset()
        with self.store.connect() as db:
            db.execute('UPDATE mac_sessions SET updated=?', (time.time() - FINISHED_RETENTION - 5,))
        self.source.tick()
        self.assertEqual(self.state(), 'needs_input', 'Unknown is not confirmed empty')
        self.adapter.owners[SESSION] = 'native-owner'
        self.receive([])
        self.source.tick()
        self.assertEqual(self.state(), 'finished', 'The result gets a fresh normal retention period')

    def test_terminal_failure_is_saved_separately_from_confirmed_attention(self):
        self.receive([dynamic('setup_codex_step', {'step': 'task'})])
        tracked = list(self.source.turn_ids.items())
        self.source._refresh_turn_statuses(tracked, outcomes={(SESSION, 'turn'): 'failed'})
        self.assertEqual(self.state(), 'needs_input')
        self.receive([])
        self.assertEqual(self.state(), 'failed')

    def test_foreign_session_old_connection_disable_shutdown_and_session_end(self):
        self.receive([dynamic('setup_codex_step', {'step': 'role'})])
        old, current = Mock(), Mock()
        self.adapter.connection = current
        self.adapter._receive(snapshot([]), connection=old)
        self.assertEqual(self.state(), 'needs_input')
        message = snapshot([])
        message['params']['conversationId'] = 'foreign'
        self.adapter._receive(message)
        self.assertEqual(self.state(), 'needs_input')
        self.event('ended', 'SessionEnd')
        self.assertEqual(self.state(), 'idle')
        self.receive([command()])
        self.assertEqual(self.state(), 'idle', 'A retired source session is not recreated by late native state')
        self.event('working', 'UserPromptSubmit', turn='next')
        self.enabled = []
        self.source.tick()
        self.receive([browser()])
        self.assertEqual(self.store.snapshot()['sessions'], [])
        self.assertEqual(self.source.native_attention, {})
        self.source.closed = True
        self.source.native_requests_changed(SESSION, PendingDecisions('native-owner', frozenset({(None, 'int', '8')})))
        self.assertEqual(self.source.native_attention, {})
        self.adapter.stop.set()
        self.adapter._receive(snapshot([command()]))
        self.assertEqual(self.store.snapshot()['sessions'], [])
