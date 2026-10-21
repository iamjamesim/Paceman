"""Recovery must distinguish confirmed decisions from last-known attention."""
from contextlib import ExitStack
import json
from pathlib import Path
import tempfile
import time
import unittest

from service.native_attention import native_unverified
from service.push import live_notification, notification_copy, should_end_live_activity
from service.status import DesktopStatus
from service.omarchy import OmarchySource
from service.processes import ProcessIdentity
from tests.test_claude_remote import REMOTE, approval
from tests.test_codex_desktop import command
from tests.test_native_attention_parity import SourceFixture


def form(rid='form'):
    return dict(type='control_request', session_id=REMOTE, request_id=rid,
                request=dict(subtype='elicitation', mode='form', mcp_server_name='server',
                             message='Choose', elicitation_id=rid))


class AttentionRecoveryTests(unittest.TestCase):
    def test_linux_restored_codex_attention_requires_a_fresh_native_set(self):
        with ExitStack() as stack:
            f = SourceFixture(stack, 'linux', 'codex')
            f.receive(command())
            f.event('Stop')
            previous = f.source
            previous.__exit__(None, None, None)
            f.source = stack.enter_context(OmarchySource(f.store, socket_path=previous.socket_path,
                state_dir=previous.state_dir, processes=previous.processes, providers=f.enabled,
                settings_reader=lambda: f.enabled, monotonic=lambda: f.clock, title_reader=lambda _: {},
                turn_metadata_reader=lambda _: {}))
            self.assertEqual(f.state(), 'idle')
            self.assertTrue(f.store.snapshot()['sessions'][0]['attentionUncertain'])
            from service.native_attention import PendingDecisions
            f.source.native_requests_changed(f.raw, PendingDecisions('new-connection', frozenset(),
                known_turns=frozenset({f.turn})))
            self.assertEqual(f.state(), 'finished')

    def test_unverified_form_does_not_hide_another_sessions_live_work(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                f.receive(form())
                f.event('Stop')
                f.adapter.disconnect()
                frame = dict(command='agent-event', session='other', turn='current', event='working', hook='UserPromptSubmit')
                if platform == 'linux':
                    frame.update(source='codex', adapter='paceman')
                    other = ProcessIdentity(101, '1', 'boot')
                    f.source.processes.identify.side_effect = lambda pid, **_kw: other if pid == 101 else f.owner
                    f.source.processes.is_alive.side_effect = lambda owner: owner in (f.owner, other)
                f.source.receive(frame, **({'peer_pid': 101} if platform == 'linux' else {}))
                snapshot = f.store.snapshot()
                self.assertEqual(snapshot['state'], 'working')
                self.assertEqual(len(snapshot['sessions']), 2)
                content = live_notification(snapshot, time.time())[0]['aps']['content-state']
                self.assertEqual((content['needsInput'], content['working']), (0, 1))

    def test_lost_form_resolution_stays_last_known_after_reconnect_and_can_later_clear(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                f.receive(form())
                f.event('Stop')
                self.assertEqual(f.state(), 'needs_input')
                f.adapter.disconnect()
                # The user answers in Claude during this gap. Its permission/
                # dialog checkpoint cannot tell us the omitted form was answered.
                for _ in range(2):
                    f.checkpoint([])
                    value = f.store.snapshot()
                    self.assertEqual(value['state'], 'idle')
                    self.assertEqual(value['sessions'][0]['state'], 'needs_input')
                    self.assertTrue(value['sessions'][0]['attentionUncertain'])
                    self.assertEqual(f.broker.pending()['requests'], [])
                self.assertTrue(should_end_live_activity(value, time.time()))
                content = live_notification(value, time.time())[0]['aps']['content-state']
                self.assertEqual(content['needsInput'], 0)
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / 'status.json'
                    DesktopStatus(path, f.store).publish(f.source, force=True)
                    status = json.loads(path.read_text())
                    self.assertEqual(status['sessionCounts']['needs_input'], 0)
                    self.assertEqual(status['unverifiedByProvider'], {'claude': 1})
                # A late exact result settles the retained request identity.
                f.event('ElicitationResult', elicitation_id='form', mcp_server_name='server')
                self.assertEqual(f.state(), 'finished')
                f.adapter._sync()
                self.assertEqual(f.state(), 'finished', 'Stale native state cannot resurrect the request')
                self.assertNotIn('attentionUncertain', f.store.snapshot()['sessions'][0])

    def test_continuous_partial_checkpoint_does_not_downgrade_a_live_form(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                f.receive(form())
                f.checkpoint([])
                self.assertEqual(f.state(), 'needs_input')
                self.assertNotIn('attentionUncertain', f.store.snapshot()['sessions'][0])

    def test_permission_answered_during_gap_clears_but_still_pending_permission_recovers(self):
        for platform in ('mac', 'linux'):
            for still_pending in (False, True):
                with self.subTest(platform=platform, pending=still_pending), ExitStack() as stack:
                    f = SourceFixture(stack, platform, 'claude')
                    f.receive(approval())
                    f.event('Stop')
                    f.adapter.disconnect()
                    self.assertEqual(f.state(), 'idle')
                    f.checkpoint([approval()] if still_pending else [])
                    self.assertEqual(f.state(), 'needs_input' if still_pending else 'finished')
                    self.assertNotIn('attentionUncertain', f.store.snapshot()['sessions'][0])

    def test_confirmed_sibling_takes_precedence_over_uncertainty_without_clearing_it(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                f.receive(form())
                f.event('Stop')
                f.adapter.disconnect()
                f.checkpoint([approval()])
                self.assertEqual(f.state(), 'needs_input')
                self.assertNotIn('attentionUncertain', f.store.snapshot()['sessions'][0])
                f.resolve('first')
                self.assertEqual(f.state(), 'idle')
                self.assertTrue(f.store.snapshot()['sessions'][0]['attentionUncertain'])
                f.resolve('form')
                self.assertEqual(f.state(), 'finished')

    def test_codex_gap_is_unverified_until_fresh_native_set_arrives(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'codex')
                f.receive(command())
                f.event('Stop')
                f.source.native_requests_changed(f.raw, None)
                self.assertEqual(f.state(), 'idle')
                self.assertTrue(f.store.snapshot()['sessions'][0]['attentionUncertain'])
                f.adapter._sync(f.raw)
                self.assertEqual(f.state(), 'needs_input')
                self.assertNotIn('attentionUncertain', f.store.snapshot()['sessions'][0])
                f.resolve(1)
                self.assertEqual(f.state(), 'finished')

    def test_state_only_waiting_recovers_without_sticky_uncertainty(self):
        for platform in ('mac', 'linux'):
            with self.subTest(platform=platform), ExitStack() as stack:
                f = SourceFixture(stack, platform, 'claude')
                f.event('Stop')
                f.checkpoint([], session_state='requires_action')
                f.adapter.disconnect()
                self.assertTrue(native_unverified(f.source.native_attention[f.key], f.turn))
                self.assertEqual(f.state(), 'idle')
                f.checkpoint([], session_state='idle')
                self.assertEqual(f.state(), 'finished')

    def test_uncertain_session_does_not_inflate_another_sessions_alert(self):
        sessions = [dict(provider='claude', state='needs_input', attentionUncertain=True),
                    dict(provider='codex', state='needs_input')]
        event = dict(state='needs_input', payload=json.dumps(dict(sourceName='Computer', sessions=sessions)))
        self.assertEqual(notification_copy(event)['title'], 'Codex needs input')
