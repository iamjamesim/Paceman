"""Native attention outlives mobile transport and individual sibling decisions."""
import tempfile
import time
from pathlib import Path
import unittest

from service.hub import Store
from service.interactions import InteractionBroker
from service.macos import MacSource
from service.push import live_notification


class ApprovalLifecycleTests(unittest.TestCase):
    def setUp(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        root.chmod(0o700)
        self.clock = 10.0
        self.store = Store(root / 'source.db')
        self.source = self.enterContext(MacSource(self.store, socket_path=root / 'hook.sock',
            allowance_reader=lambda: None, turn_status_reader=lambda _: {}, title_reader=lambda _: {},
            monotonic=lambda: self.clock))
        self.source.next_turn_status_at = float('inf')
        self.send('working', 'UserPromptSubmit')

    def send(self, event, hook, **extra):
        return self.source.receive(dict(command='agent-event', session='one', turn='1', event=event, hook=hook, **extra))

    def debounce(self):
        self.clock += 6
        self.source.tick()

    def test_mobile_deadline_does_not_clear_a_native_approval_or_live_activity_attention(self):
        self.send('needs-input', 'PermissionRequest', approvalToken='approval', attentionKey='command')
        self.debounce()
        broker = InteractionBroker(clock=lambda: self.clock)
        self.addCleanup(broker.close)
        pending = broker._publish(dict(provider='codex', sessionID=self.store.snapshot()['sessions'][0]['id'],
            kind='approval', title='Approval', detail='Synthetic request'), 600)
        self.clock += 601
        self.assertEqual(broker.pending()['requests'], [])
        self.assertEqual(pending.response, {'action': 'release'})
        self.send('working', 'UserPromptSubmit')
        self.send('working', 'PostToolUse', attentionKey='unrelated', toolID='other-call')
        self.source.tick()
        snapshot = self.store.snapshot()
        self.assertEqual(snapshot['state'], 'needs_input')
        content = live_notification(snapshot, time.time())[0]['aps']['content-state']
        self.assertEqual((content['needsInput'], content['working']), (1, 0))
        self.send('working', 'PostToolUse', attentionKey='command', toolID='approved-call')
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_approval_and_question_resolve_independently_in_either_order(self):
        for order in [('approval', 'question'), ('question', 'approval')]:
            with self.subTest(order=order):
                self.send('needs-input', 'PermissionRequest', approvalToken='approval', attentionKey='command')
                self.send('question-opened', 'PreToolUse', toolID='question-call')
                self.debounce()
                for index, kind in enumerate(order):
                    if kind == 'approval':
                        self.send('working', 'PostToolUse', attentionKey='command', toolID='approved-' + order[0])
                    else:
                        self.send('question-answered', 'PostToolUse', toolID='question-call')
                    self.assertEqual(self.store.snapshot()['state'], 'needs_input' if index == 0 else 'working')
