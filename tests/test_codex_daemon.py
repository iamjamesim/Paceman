import time
import unittest
from unittest.mock import Mock

from service.codex_daemon import DaemonRequests
from service.interactions import InteractionBroker, BrokerError


def request(rid=1, turn='turn', command='echo proof'):
    return dict(id=rid, method='item/commandExecution/requestApproval', params=dict(
        threadId='session', turnId=turn, itemId='item', command=command,
        availableDecisions=['accept', 'acceptForSession', 'cancel']))


def wait_for(predicate):
    deadline = time.monotonic() + 2
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError('condition did not complete')
        time.sleep(.005)


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.broker = InteractionBroker()
        self.addCleanup(self.broker.close)
        self.sessions = {'session': 'turn'}
        self.attention = []
        self.adapter = DaemonRequests(self.broker, lambda: self.sessions,
            attention=lambda *v: self.attention.append(v))
        self.connection = Mock()
        self.adapter.connection = self.connection
        self.adapter.joined['session'] = 'turn'
        self.adapter.ready.add('session')
        self.adapter.items['session'] = {}
        self.addCleanup(self.adapter._reset)

    def submit(self, option='decision-0'):
        r = self.broker.pending()['requests'][0]
        return self.broker.submit(dict(generation=self.broker.generation, requestID=r['requestID'],
            version=1, idempotencyKey='proof', action='choose', optionID=option))

    def test_replayed_live_request_keeps_all_native_choices_and_exact_response_id(self):
        self.adapter.receive(request(0))
        self.assertEqual([o['label'] for o in self.broker.pending()['requests'][0]['responseOptions']],
                         ['Allow once', 'Allow for this session', 'Cancel this turn'])
        self.submit('decision-1')
        wait_for(lambda: self.connection.send.called)
        self.connection.send.assert_called_once_with(dict(id=0, result=dict(decision='acceptForSession')))
        self.assertTrue(self.attention[-1][1]['turn'], 'Submission is not native consumption')
        self.adapter.receive(dict(method='serverRequest/resolved', params=dict(threadId='session', requestId=0)))
        self.assertFalse(self.attention[-1][1]['turn'])

    def test_local_answer_withdraws_only_exact_native_request_immediately(self):
        self.adapter.receive(request(1))
        first = self.broker.pending()['requests'][0]
        self.adapter.receive(request(2))
        self.adapter.receive(dict(method='serverRequest/resolved', params=dict(threadId='session', requestId=1)))
        self.assertEqual(len(self.broker.pending()['requests']), 1)
        self.assertTrue(self.attention[-1][1]['turn'])
        with self.assertRaises(BrokerError):
            self.broker.submit(dict(generation=self.broker.generation, requestID=first['requestID'],
                version=1, idempotencyKey='late', action='choose', optionID='decision-0'))
        self.connection.send.assert_not_called()

    def test_foreign_thread_and_old_turn_requests_are_not_answerable(self):
        self.adapter.receive(request(turn='old'))
        other = request(); other['params']['threadId'] = 'another'
        self.adapter.receive(other)
        self.assertEqual(self.broker.pending()['requests'], [])

    def test_native_review_mutation_invalidates_previous_remote_card(self):
        self.adapter.receive(request())
        self.adapter.receive(request(command='a different command'))
        self.assertEqual(self.broker.pending()['requests'], [])
        self.connection.send.assert_not_called()

    def test_replayed_file_approval_waits_for_its_real_patch_and_updates_invalidate_card(self):
        raw = dict(id='file', method='item/fileChange/requestApproval', params=dict(
            threadId='session', turnId='turn', itemId='patch', availableDecisions=['accept', 'cancel']))
        self.adapter.receive(raw)
        self.assertEqual(self.broker.pending()['requests'], [])
        self.adapter.receive(dict(method='item/fileChange/patchUpdated', params=dict(threadId='session',
            turnId='turn', itemId='patch', changes=[dict(path='/tmp/proof', kind={'type':'add'}, diff='+proof')])) )
        self.assertEqual(len(self.broker.pending()['requests']), 1)
        self.adapter.receive(dict(method='item/fileChange/patchUpdated', params=dict(threadId='session',
            turnId='turn', itemId='patch', changes=[dict(path='/tmp/proof', kind={'type':'add'}, diff='+changed')])) )
        self.assertEqual(self.broker.pending()['requests'], [])

    def test_release_and_disconnect_never_make_native_decisions(self):
        self.adapter.receive(request())
        self.broker.cancel_all()
        wait_for(lambda: bool(self.adapter.retired))
        self.adapter._sync('session')
        self.assertEqual(self.broker.pending()['requests'], [])
        self.adapter._reset()
        self.connection.send.assert_not_called()
        self.assertIsNone(self.attention[-1][1])

    def test_source_turn_change_rejects_answer_without_forwarding_it(self):
        self.adapter.receive(request())
        self.sessions['session'] = 'next'
        self.submit()
        handle = next(iter(self.adapter.pending.values()))[0]
        self.assertTrue(handle.ready.wait(1))
        self.adapter._forget('session')
        self.connection.send.assert_not_called()

    def test_uncertain_send_is_not_retried(self):
        self.adapter.receive(request())
        self.connection.send.side_effect = OSError('uncertain')
        self.submit()
        wait_for(lambda: self.connection.send.called)
        self.adapter._sync('session')
        self.assertEqual(self.connection.send.call_count, 1)
        self.connection.close.assert_called_once()

    def test_unknown_live_requests_preserve_native_attention(self):
        raw = request(); raw['method'] = 'item/permissions/requestApproval'
        self.adapter.receive(raw)
        self.assertEqual(self.broker.pending()['requests'], [])
        self.assertTrue(self.attention[-1][1]['turn'])
