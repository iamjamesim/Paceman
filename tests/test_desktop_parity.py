"""Exercise the failure boundaries shared by the two desktop clients."""
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from macos.claude_hook import message_for
from omarchy import codex_hook
from service import hook_delivery
from service.hub import Store
from service.macos import MacSource
from service.omarchy import OmarchySource
from service.processes import ProcessIdentity
from service.native_attention import PendingDecisions
from tests.test_native_attention_parity import SourceFixture
from tests.test_codex_desktop import command


class DesktopOutcomeTests(unittest.TestCase):
    def test_native_completion_without_stop_or_saved_history_finishes_on_both_platforms(self):
        for platform in ('mac', 'linux'):
            for outcome, expected in (('completed', 'finished'), ('failed', 'failed'), ('interrupted', 'idle')):
                with self.subTest(platform=platform, outcome=outcome), ExitStack() as stack:
                    f = SourceFixture(stack, platform, 'codex')
                    self.assertEqual(f.state(), 'working')
                    f.receive(dict(method='turn/completed', params=dict(threadId=f.raw,
                        turn=dict(id=f.turn, status=outcome))))
                    self.assertEqual(f.state(), expected)

    def test_failure_outcome_and_sibling_decisions_have_independent_lifetimes(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'codex')
                f.receive(command(1))
                f.receive(command(2))
                f.receive(dict(method='turn/completed', params=dict(threadId=f.raw,
                    turn=dict(id=f.turn, status='failed'))))
                self.assertEqual(f.state(), 'needs_input')
                f.resolve(1)
                self.assertEqual(f.state(), 'needs_input')
                f.resolve(2)
                self.assertEqual(f.state(), 'failed')
                f.receive(dict(method='turn/completed', params=dict(threadId=f.raw,
                    turn=dict(id=f.turn, status='completed'))))
                self.assertEqual(f.state(), 'failed')
                f.event('UserPromptSubmit', turn='new-turn')
                f.receive(dict(method='turn/completed', params=dict(threadId=f.raw,
                    turn=dict(id='turn', status='completed'))))
                self.assertEqual(f.state(), 'working')

    def test_safe_project_labels_reach_both_sources_without_paths(self):
        for platform in ('mac', 'linux'):
            for provider in ('codex', 'claude'):
                with self.subTest(platform=platform, provider=provider), ExitStack() as stack:
                    f = SourceFixture(stack, platform, provider)
                    frame = dict(command='agent-event', provider=provider, session=f.raw, turn='next',
                        event='working', hook='UserPromptSubmit', workspaceLabel='paceman')
                    if platform == 'linux':
                        frame.update(source='codex', adapter='paceman')
                    f.source.receive(frame, **({'peer_pid': 100} if platform == 'linux' else {}))
                    self.assertEqual(f.store.snapshot()['sessions'][0]['workspaceLabel'], 'paceman')
                    frame.update(turn='third', workspaceLabel='/private/project/path')
                    f.source.receive(frame, **({'peer_pid': 100} if platform == 'linux' else {}))
                    self.assertNotIn('/private/project/path', json.dumps(f.store.snapshot()))

    def test_late_saved_completion_cannot_replace_newer_native_failure(self):
        with ExitStack() as stack:
            f = SourceFixture(stack, 'linux', 'codex')
            def read(_):
                f.receive(dict(method='turn/completed', params=dict(threadId=f.raw,
                    turn=dict(id=f.turn, status='failed'))))
                return {f.raw: [dict(id=f.turn, status='completed')]}
            f.source.turn_metadata_reader = read
            f.source._recover_turns([({'id': f.key, 'turn': f.turn}, f.owner)], {})
            self.assertEqual(f.state(), 'failed')


class MacClaudeRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.store = Store(self.root / 'hub.sqlite3')
        self.owner = ProcessIdentity(100, 'start-1', 'boot-1')
        self.alive = True
        self.clock = 100.0
        self.processes = Mock()
        self.processes.identify.side_effect = lambda *_a, **_kw: self.owner
        self.processes.is_alive.side_effect = lambda owner: self.alive and owner == self.owner

    def source(self, **options):
        return MacSource(self.store, socket_path=self.root / 'hook.sock', processes=self.processes,
            allowance_reader=lambda: [], turn_status_reader=lambda _: {}, turn_metadata_reader=lambda _: {},
            title_reader=lambda _: {}, monotonic=lambda: self.clock, **options)

    def hook(self, source, hook='UserPromptSubmit', turn='turn', **extra):
        with patch.dict(os.environ, CLAUDE_CODE_BRIDGE_SESSION_ID='session_verified'):
            frame = message_for(dict(hook_event_name=hook, session_id='claude-local', prompt_id=turn,
                cwd=str(self.root / 'project'), prompt='PRIVATE PROMPT', **extra))
        source.receive(frame, peer_pid=200)

    def test_restart_preserves_verified_main_and_child_waits_and_remote_binding(self):
        with self.source() as source:
            self.hook(source)
            self.hook(source, 'PreToolUse', tool_name='AskUserQuestion', tool_use_id='question')
            self.hook(source, 'PermissionRequest', agent_id='child', tool_name='Bash')
            self.clock += 6
            source.tick()
            self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        with self.source() as source:
            self.assertEqual(self.store.snapshot()['state'], 'needs_input')
            row = self.store.snapshot()['sessions'][0]
            self.assertEqual(row['workspaceLabel'], 'project')
            self.assertEqual(row['remoteSessionID'], 'session_verified')
            self.assertEqual(source.native_claude_owner(row['id'], 'session_verified'), self.owner)
            self.hook(source, 'PostToolUse', tool_name='AskUserQuestion', tool_use_id='question')
            self.assertEqual(self.store.snapshot()['state'], 'needs_input', 'Child wait still owns attention')
            self.hook(source, 'SubagentStop', agent_id='child')
            self.assertEqual(self.store.snapshot()['state'], 'working')
            self.hook(source, 'Stop')
            self.assertEqual(self.store.snapshot()['state'], 'finished')
            with self.store.connect() as db:
                self.assertNotIn('PRIVATE PROMPT', '\n'.join(db.iterdump()))

    def test_exit_pid_reuse_and_boot_change_cannot_restore_active_work(self):
        for boundary in ('exit', 'pid-reuse', 'reboot'):
            with self.subTest(boundary=boundary):
                with self.source() as source:
                    self.alive = True
                    self.hook(source)
                if boundary == 'exit':
                    self.alive = False
                elif boundary == 'pid-reuse':
                    self.owner = ProcessIdentity(100, 'start-2', 'boot-1')
                else:
                    self.owner = ProcessIdentity(100, 'start-2', 'boot-2')
                with self.source() as source:
                    self.assertEqual(self.store.snapshot()['sessions'], [])
                    self.assertEqual(source.native_claude_sessions(), [])
                    with self.store.connect() as db:
                        self.assertEqual(db.execute('SELECT COUNT(*) FROM mac_claude_tracking').fetchone()[0], 0)

    def test_owner_exit_clears_activity_without_end_hook_and_preserves_results(self):
        for finished in (False, True):
            with self.subTest(finished=finished), self.source() as source:
                self.alive = True
                self.hook(source)
                if finished:
                    self.hook(source, 'Stop')
                self.alive = False
                self.clock += 2
                source.tick()
                self.assertFalse(source.claude_sessions)
                self.assertEqual(self.store.snapshot()['state'], 'finished' if finished else 'idle')

    def test_native_decisions_are_not_persisted_and_old_end_cannot_clear_new_turn(self):
        key = hashlib.sha256(b'claude:claude-local').hexdigest()
        with self.source() as source:
            self.hook(source)
            source.native_claude_requests_changed(key, 'turn', PendingDecisions('session_verified',
                frozenset({(None, 'str', 'private-native-request')})))
            self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        with self.source() as source:
            self.assertFalse(source.native_attention)
            self.assertEqual(self.store.snapshot()['state'], 'working')
            self.hook(source, turn='next')
            self.hook(source, 'SessionEnd')
            self.assertEqual(self.store.snapshot()['state'], 'working')
            source.settings_reader = lambda: ['codex']
            source._apply_settings()
            with self.store.connect() as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM mac_claude_tracking').fetchone()[0], 0)
                self.assertNotIn('private-native-request', '\n'.join(db.iterdump()))

    def test_late_child_result_after_owner_replacement_clears_old_snapshot(self):
        with self.source() as source:
            self.hook(source)
            self.owner = ProcessIdentity(100, 'new-start', 'boot-1')
            self.hook(source, 'PostToolUse', agent_id='child', tool_name='Bash', tool_use_id='old-call')
            self.assertEqual(self.store.snapshot()['state'], 'idle')
            self.assertFalse(source.claude_sessions)


class OmarchyDeliveryAndUsageTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.store = Store(self.root / 'hub.sqlite3')
        self.processes = Mock()
        self.processes.identify.return_value = ProcessIdentity(100, 'start', 'boot')
        self.processes.is_alive.return_value = True

    def source(self, **options):
        return OmarchySource(self.store, socket_path=self.root / 'omarchy-watch.sock', state_dir=self.root,
            processes=self.processes, allowance_reader=options.pop('allowance_reader', lambda: []),
            turn_metadata_reader=lambda _: {}, title_reader=lambda _: {}, **options)

    def quota(self, remaining=65, updated=None):
        now = int(time.time()) if updated is None else updated
        return dict(provider='codex', remaining=remaining, window=2, windowDurationMins=300,
                    updatedAt=now, resetsAt=now + 3600)

    def test_usage_works_without_external_file_and_failure_preserves_observation_time(self):
        with self.source() as source:
            source.allowance_thread.join(2)
            before = self.store.snapshot()
            quota = self.quota()
            source.allowance_reader = lambda: [quota]
            source._refresh_allowance(source.usage_generation)
            after = self.store.snapshot()
            self.assertEqual(after['allowances'], [quota])
            self.assertEqual(after['eventID'], before['eventID'])
            self.assertFalse((self.root / 'agents/usage/codex.json').exists())
            source.allowance_reader = Mock(side_effect=OSError('unavailable'))
            source._refresh_allowance(source.usage_generation)
            self.assertEqual(self.store.snapshot()['allowances'], [quota])

    def test_late_usage_result_cannot_undo_disable_or_shutdown(self):
        for boundary in ('disable', 'reenable', 'shutdown'):
            with self.subTest(boundary=boundary):
                with self.source() as source:
                    source.allowance_thread.join(2)
                    generation = source.usage_generation
                    def read():
                        if boundary == 'shutdown':
                            source.closed = True
                        else:
                            source.settings_reader = lambda: ['claude']
                            with self.store.connect() as db:
                                source.apply_settings(db)
                                source.publish(db)
                            if boundary == 'reenable':
                                source.settings_reader = lambda: ['codex', 'claude']
                                with self.store.connect() as db:
                                    source.apply_settings(db)
                                    source.publish(db)
                        return [self.quota()]
                    source.allowance_reader = read
                    source._refresh_allowance(generation)
                    self.assertEqual(self.store.snapshot()['allowances'], [])

    def test_terminal_hook_retries_after_failed_connection_and_sends_project_label(self):
        with ExitStack() as stack, patch.object(codex_hook, 'socket_path', return_value=self.root / 'omarchy-watch.sock'), \
                patch.object(hook_delivery, 'time') as clock:
            clock.monotonic.return_value = 0.0
            def restart(delay):
                self.assertEqual(delay, .1)
                stack.enter_context(self.source())
            clock.sleep.side_effect = restart
            codex_hook.process(dict(hook_event_name='Stop', turn_id='turn', cwd=str(self.root / 'project')), 'session')
            clock.sleep.assert_called_once_with(.1)
            row = self.store.snapshot()['sessions'][0]
            self.assertEqual(row['state'], 'finished')
            self.assertEqual(row['workspaceLabel'], 'project')
            self.assertNotIn(str(self.root), json.dumps(self.store.snapshot()))
