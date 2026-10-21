"""Run the same provider decision fixtures through Mac and Linux sources."""
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from service.claude_hooks import message_for
from service.claude_remote import NativeRequests
from service.codex_daemon import DaemonRequests
from service.hub import Store
from service.interactions import InteractionBroker
from service.macos import MacSource, FINISHED_RETENTION
from service.omarchy import OmarchySource
from service.processes import AgentProcesses, ProcessIdentity
from service.native_attention import PendingDecisions
from tests.test_claude_remote import REMOTE, approval, envelope, wait_for
from tests.test_codex_desktop import SESSION, command, browser


class SourceFixture:
    def __init__(self, stack, platform, provider):
        root = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        root.chmod(0o700)
        self.store = Store(root / 'hub.sqlite3')
        self.platform, self.provider = platform, provider
        self.clock, self.turn, self.sequence = 100.0, 'turn', 0
        self.enabled = ['codex', 'claude']
        self.owner = ProcessIdentity(100, '1', 'boot')
        processes = Mock(spec=AgentProcesses)
        processes.identify.side_effect = lambda *_a, **_kw: self.owner
        processes.is_alive.side_effect = lambda owner: owner == self.owner
        common = dict(socket_path=root / 'hook.sock', providers=self.enabled,
            settings_reader=lambda: self.enabled, monotonic=lambda: self.clock, title_reader=lambda _: {})
        if platform == 'mac':
            self.source = stack.enter_context(MacSource(self.store, **common,
                allowance_reader=lambda: None, turn_status_reader=lambda _: {}, turn_metadata_reader=lambda _: {}))
            self.source.next_allowance_at = self.source.next_turn_status_at = float('inf')
        else:
            self.source = stack.enter_context(OmarchySource(self.store, **common,
                state_dir=root, processes=processes, turn_metadata_reader=lambda _: {}))
        self.raw = SESSION if provider == 'codex' else 'native-local'
        self.key = hashlib.sha256((provider + ':' + self.raw).encode()).hexdigest()
        self.event('UserPromptSubmit')
        self.broker = InteractionBroker(provider_enabled=lambda provider: provider in self.source.providers)
        stack.callback(self.broker.close)
        self.sent = []
        if provider == 'codex':
            self.adapter = DaemonRequests(self.broker, self.source.native_response_sessions,
                attention=self.source.native_requests_changed)
            self.adapter.joined[self.raw] = self.turn
            self.adapter.ready.add(self.raw)
            self.adapter.items[self.raw] = {}
            self.adapter.connection = Mock()
            stack.callback(self.adapter._reset)
        else:
            self.adapter = NativeRequests(self.broker, self.key, REMOTE, self.sent.append,
                attention=lambda value: self.source.native_claude_requests_changed(self.key, self.turn, value),
                resolved=lambda tools, pending: self.source.native_claude_requests_resolved(self.key, self.turn, tools, pending))
            stack.callback(self.adapter.close)
            self.checkpoint([])

    def event(self, hook, **fields):
        turn = fields.pop('turn', self.turn)
        if hook == 'UserPromptSubmit':
            self.turn = turn
        if self.provider == 'codex':
            event = {'UserPromptSubmit': 'working', 'Stop': 'completed', 'SessionEnd': 'ended',
                     'PermissionRequest': 'needs-input'}[hook]
            frame = dict(command='agent-event', session=self.raw, turn=turn, event=event, hook=hook)
            if self.platform == 'linux':
                frame.update(source='codex', adapter='paceman')
        else:
            with patch.dict(os.environ, CLAUDE_CODE_BRIDGE_SESSION_ID=REMOTE):
                frame = message_for(dict(session_id=self.raw, prompt_id=turn, hook_event_name=hook, **fields))
            if frame is None:
                return
        self.source.receive(frame, **({'peer_pid': 100} if self.platform == 'linux' else {}))

    def receive(self, frame, source='worker'):
        if self.provider == 'codex':
            self.adapter.receive(frame)
        else:
            self.sequence += 1
            self.adapter.receive('client_event', envelope(frame, self.sequence, source))

    def checkpoint(self, requests, **response):
        self.adapter.initialize()
        self.receive(dict(type='control_response', session_id=REMOTE, response=dict(subtype='success',
            request_id=self.sent[-1]['request_id'], response=dict(pid=42, **response),
            pending_permission_requests=requests, pending_user_dialog_requests=[])))

    def resolve(self, rid):
        if self.provider == 'codex':
            self.receive(dict(method='serverRequest/resolved', params=dict(threadId=self.raw, requestId=rid)))
        else:
            self.receive(dict(type='control_cancel_request', session_id=REMOTE, request_id=rid))

    def state(self):
        return self.store.snapshot()['state']


class PlatformDecisionParityTests(unittest.TestCase):
    def test_claude_owner_requires_action_survives_stop_without_a_response_card(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                f.event('Stop')
                f.checkpoint([], session_state='requires_action')
                self.assertEqual(f.state(), 'needs_input')
                self.assertEqual(f.broker.pending()['requests'], [])
                f.checkpoint([], session_state='running')
                self.assertEqual(f.state(), 'finished')

    def test_linux_restored_claude_aggregate_is_unknown_to_partial_checkpoints(self):
        with ExitStack() as stack:
            f = SourceFixture(stack, 'linux', 'claude')
            f.receive(approval())
            f.event('Stop')
            previous = f.source
            previous.__exit__(None, None, None)
            f.source = stack.enter_context(OmarchySource(f.store, socket_path=previous.socket_path,
                state_dir=previous.state_dir, processes=previous.processes, providers=f.enabled,
                settings_reader=lambda: f.enabled, monotonic=lambda: f.clock, title_reader=lambda _: {},
                turn_metadata_reader=lambda _: {}))
            self.assertEqual(f.state(), 'needs_input')
            f.source.native_claude_requests_changed(f.key, f.turn, PendingDecisions(REMOTE, frozenset()))
            self.assertEqual(f.state(), 'needs_input', 'A partial checkpoint cannot resolve restored identities that were intentionally not persisted')
            f.event('SessionEnd')
            self.assertEqual(f.store.snapshot()['sessions'], [])

    def test_confirmed_empty_codex_turn_clears_hook_attention_but_disconnect_does_not(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'codex')
                f.event('PermissionRequest')
                f.clock += 6
                f.source.tick(**({'force': True} if platform == 'linux' else {}))
                self.assertEqual(f.state(), 'needs_input')
                f.source.native_requests_changed(f.raw, None)
                self.assertEqual(f.state(), 'needs_input')
                f.adapter._sync(f.raw)
                self.assertEqual(f.state(), 'working', 'A known turn with a confirmed empty native set resolves its stale hook wait')

    def test_supported_responses_keep_exact_native_identity_and_sibling_attention(self):
        for platform in ('mac', 'linux'):
            for provider in ('codex', 'claude'):
                with self.subTest(platform=platform, provider=provider), ExitStack() as stack:
                    f = SourceFixture(stack, platform, provider)
                    for rid in ('first', 'sibling'):
                        f.receive(command(rid) if provider == 'codex' else approval(rid))
                    first = f.broker.pending()['requests'][0]
                    option = 'decision-1' if provider == 'codex' else 'once'
                    f.broker.submit(dict(generation=f.broker.generation, requestID=first['requestID'], version=1,
                        idempotencyKey='answer', action='choose', optionID=option))
                    if provider == 'codex':
                        wait_for(lambda: f.adapter.connection.send.called)
                        self.assertEqual(f.adapter.connection.send.call_args.args[0],
                                         dict(id='first', result=dict(decision='acceptForSession')))
                    else:
                        wait_for(lambda: len(f.sent) == 2)
                        self.assertEqual(f.sent[-1]['response']['request_id'], 'first')
                        self.assertEqual(f.sent[-1]['response']['response']['behavior'], 'allow')
                    f.event('Stop')
                    self.assertEqual(f.state(), 'needs_input')
                    f.resolve('first')
                    self.assertEqual(f.broker.pending()['awaitingRequestIDs'], [])
                    self.assertEqual(f.state(), 'needs_input')
                    f.resolve('sibling')
                    self.assertEqual(f.state(), 'finished')

    def test_stop_order_siblings_disconnect_and_restored_outcome(self):
        for platform in ('mac', 'linux'):
            for provider in ('codex', 'claude'):
                for stop_first in (True, False):
                    with self.subTest(platform=platform, provider=provider, stop_first=stop_first), ExitStack() as stack:
                        f = SourceFixture(stack, platform, provider)
                        if stop_first:
                            f.event('Stop')
                        if provider == 'codex':
                            for rid in (1, 2):
                                frame = command(rid); frame['method'] = 'item/permissions/requestApproval'
                                f.receive(frame)
                        else:
                            for rid in ('1', '2'):
                                frame = approval(rid, requires_user_interaction=True)
                                f.receive(frame)
                        if not stop_first:
                            f.event('Stop')
                        self.assertEqual(f.state(), 'needs_input')
                        self.assertEqual(f.broker.pending()['requests'], [], 'Known native-only prompts use native continuation')
                        f.resolve(1 if provider == 'codex' else '1')
                        self.assertEqual(f.state(), 'needs_input')
                        f.resolve(2 if provider == 'codex' else '2')
                        self.assertEqual(f.state(), 'finished')
                        self.assertEqual(f.broker.pending()['awaitingRequestIDs'], [])

    def test_claude_elicitation_is_session_scoped_and_hook_resolution_has_tombstones(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                frame = dict(type='control_request', session_id=REMOTE, request_id='form', request=dict(
                    subtype='elicitation', mode='form', mcp_server_name='server', message='Choose', elicitation_id='form-id'))
                f.receive(frame)
                self.assertEqual(f.state(), 'needs_input')
                f.event('Stop')
                f.event('UserPromptSubmit', turn='next')
                self.assertEqual(f.state(), 'needs_input', 'Remote IDs do not acquire an invented hook turn')
                f.event('Stop')
                f.checkpoint([])
                self.assertEqual(f.state(), 'needs_input', 'Permission/dialog checkpoint cannot resolve elicitation')
                f.event('ElicitationResult', elicitation_id='form-id', mcp_server_name='server')
                self.assertEqual(f.state(), 'finished')
                f.adapter._sync()
                self.assertEqual(f.state(), 'finished', 'Stale reducer state cannot reopen the hook-resolved ID')

    def test_ambiguous_elicitation_server_fallback_does_not_clear_siblings(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                for rid in ('a', 'b'):
                    f.receive(dict(type='control_request', session_id=REMOTE, request_id=rid, request=dict(
                        subtype='elicitation', mcp_server_name='server', message='Choose')))
                f.event('Stop')
                f.event('ElicitationResult', mcp_server_name='server')
                self.assertEqual(f.state(), 'needs_input')
                f.resolve('a')
                self.assertEqual(f.state(), 'needs_input')
                f.event('ElicitationResult', mcp_server_name='server')
                self.assertEqual(f.state(), 'finished', 'Single remaining scoped form can be matched')

    def test_child_hook_attention_outlives_parent_turn_without_cross_actor_clearing(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                for actor in ('child-a', 'child-b'):
                    f.event('PreToolUse', agent_id=actor, tool_name='Bash', tool_use_id='same')
                    f.event('PermissionRequest', agent_id=actor, tool_name='Bash')
                f.clock += 6
                f.event('Stop')
                self.assertEqual(f.state(), 'needs_input')
                f.event('Stop', agent_id='child-a')
                self.assertEqual(f.state(), 'needs_input', 'Child Stop cannot change the saved parent outcome')
                f.event('UserPromptSubmit', turn='next')
                f.event('PostToolUse', agent_id='child-a', tool_name='Bash', tool_use_id='same')
                self.assertEqual(f.state(), 'needs_input')
                f.event('PostToolBatch')
                self.assertEqual(f.state(), 'needs_input', 'Parent batches cannot clear child decisions')
                f.event('Stop')
                f.event('SubagentStop', agent_id='child-b', turn='')
                self.assertEqual(f.state(), 'finished')
                f.event('SessionEnd')
                f.event('SubagentStop', agent_id='child-b', turn='')
                self.assertEqual(f.store.snapshot()['sessions'], [], 'A late child completion cannot recreate a closed session')

    def test_remote_child_resolution_clears_only_matching_hook_wait(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                f.event('PreToolUse', agent_id='child', tool_name='AskUserQuestion', tool_use_id='ask')
                f.clock += 6
                raw = approval('ask', agent_id='child')
                raw['request'].update(tool_name='AskUserQuestion', tool_use_id='ask', input={'questions': []})
                f.receive(raw)
                f.event('Stop')
                self.assertEqual(f.state(), 'needs_input')
                self.assertEqual(f.broker.pending()['requests'], [], 'Agent-scoped dialogs keep their native workflow')
                f.resolve('ask')
                self.assertEqual(f.state(), 'finished')

    def test_internal_unknown_and_stale_owner_or_turn_do_not_create_attention(self):
        for platform in ('mac', 'linux'):
            for provider in ('codex', 'claude'):
                with self.subTest(platform=platform, provider=provider), ExitStack() as stack:
                    f = SourceFixture(stack, platform, provider)
                    if provider == 'codex':
                        for method in ('currentTime/read', 'item/tool/call', 'unknown/method'):
                            frame = command(); frame['method'] = method
                            f.receive(frame)
                    else:
                        for subtype in ('hook_callback', 'mcp_message', 'unknown_request'):
                            f.receive(dict(type='control_request', session_id=REMOTE,
                                request_id=subtype, request=dict(subtype=subtype)))
                        f.source.native_claude_requests_changed(f.key, 'old', PendingDecisions(REMOTE,
                            frozenset({(None, 'str', 'stale')})))
                        f.source.native_claude_requests_changed(f.key, f.turn, PendingDecisions('different-owner',
                            frozenset({(None, 'str', 'stale')})))
                    self.assertEqual(f.state(), 'working')
                    self.assertEqual(f.broker.pending()['requests'], [])
                    f.enabled = []
                    f.source.tick(**({'force': True} if platform == 'linux' else {}))
                    if provider == 'codex':
                        f.receive(command())
                    else:
                        f.receive(approval())
                    self.assertEqual(f.store.snapshot()['sessions'], [])
