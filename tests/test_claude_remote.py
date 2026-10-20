import io
import hashlib
import json
import threading
import time
import unittest
from unittest.mock import Mock

from service.claude_remote import NativeRequests, NativeHTTP, events
from service.claude_requests import decode_request
from service.interactions import BrokerError, InteractionBroker


REMOTE = 'session_native_proof'
SESSION = hashlib.sha256(b'claude:native-local').hexdigest()


def approval(rid='first', **fields):
    return dict(type='control_request', session_id=REMOTE, request_id=rid, request=dict(
        subtype='can_use_tool', tool_name='Bash', tool_use_id='tool-'+rid,
        input={'command': 'python3 -c "print(1)"'}, **fields))


def envelope(frame, sequence, source='worker'):
    return dict(sequence_num=sequence, source=source, payload=frame)


def wait_for(predicate):
    limit = time.monotonic() + 2
    while not predicate():
        if time.monotonic() >= limit:
            raise AssertionError('condition did not complete')
        time.sleep(.005)


class NativeClaudeTests(unittest.TestCase):
    def setUp(self):
        self.broker = InteractionBroker()
        self.addCleanup(self.broker.close)
        self.sent, self.attention = [], []
        self.adapter = NativeRequests(self.broker, SESSION, REMOTE, self.sent.append, self.attention.append)
        self.addCleanup(self.adapter.disconnect)
        self.sequence = 0

    def receive(self, frame, source='worker'):
        self.sequence += 1
        self.adapter.receive('client_event', envelope(frame, self.sequence, source))

    def checkpoint(self, requests):
        self.adapter.initialize()
        rid = self.sent[-1]['request_id']
        self.assertEqual(self.sent[-1]['request'], {'subtype': 'initialize'})
        self.receive(dict(type='control_response', session_id=REMOTE, response=dict(subtype='success',
            request_id=rid, response={'pid': 42}, pending_permission_requests=requests,
            pending_user_dialog_requests=[])))

    def submit(self, request, option='once'):
        return self.broker.submit(dict(generation=self.broker.generation,
            requestID=request['requestID'], version=1, idempotencyKey='proof-response',
            action='choose', optionID=option))

    def test_replay_never_publishes_historical_prompts_before_owner_checkpoint(self):
        self.receive(approval('old'))
        self.assertEqual(self.broker.pending()['requests'], [])
        self.checkpoint([approval('current')])
        self.assertEqual(len(self.broker.pending()['requests']), 1)
        self.assertEqual(set(self.adapter.native), {'current'})

    def test_wire_sequences_are_decimal_strings_and_owner_frames_use_local_session_id(self):
        self.checkpoint([])
        frame = approval(); frame['session_id'] = 'native-local'
        self.sequence += 1
        self.adapter.receive('client_event', envelope(frame, str(self.sequence)))
        self.assertEqual(len(self.broker.pending()['requests']), 1)
        frame = approval('alias'); frame['session_id'] = 'cse_native_proof'
        self.sequence += 1
        self.adapter.receive('client_event', envelope(frame, str(self.sequence)))
        self.assertEqual(len(self.broker.pending()['requests']), 2)
        frame = approval('wrong'); frame['session_id'] = 'a different local session'
        with self.assertRaises(ValueError):
            self.adapter.receive('client_event', envelope(frame, self.sequence+1))

    def test_local_answer_immediately_withdraws_exact_card_without_waiting_for_tool_completion(self):
        self.checkpoint([approval('first'), approval('sibling')])
        first, sibling = self.broker.pending()['requests']
        self.receive(dict(type='control_response', session_id=REMOTE, response=dict(
            request_id='first', subtype='success', response={'behavior': 'allow'})))
        self.assertEqual([r['requestID'] for r in self.broker.pending()['requests']], [sibling['requestID']])
        self.assertTrue(self.attention[-1])
        with self.assertRaises(BrokerError):
            self.submit(first)
        self.receive(dict(type='control_cancel_request', session_id=REMOTE, request_id='sibling'))
        self.assertEqual(self.broker.pending()['requests'], [])
        self.assertFalse(self.attention[-1])

    def test_identical_concurrent_calls_retain_native_identity_and_exact_permission_scope(self):
        suggestion = dict(type='addRules', behavior='allow', destination='localSettings',
                          rules=[dict(toolName='Bash', ruleContent='python3 -c proof')])
        self.checkpoint([approval('first', permission_suggestions=[suggestion]), approval('sibling')])
        first, sibling = self.broker.pending()['requests']
        self.assertIn('this project (local settings)', first['responseOptions'][1]['label'])
        self.submit(first, 'suggestion-0')
        wait_for(lambda: len(self.sent) == 2)
        self.assertEqual(self.sent[-1], dict(type='control_response', response=dict(subtype='success',
            request_id='first', response=dict(behavior='allow', updatedPermissions=[suggestion],
                                             updatedInput=approval()['request']['input']))))
        self.assertEqual([r['requestID'] for r in self.broker.pending()['requests']], [sibling['requestID']])
        self.assertTrue(self.attention[-1], 'Submission is not native consumption')

    def test_approval_response_preserves_input_and_decline_supplies_native_reason(self):
        frame = approval()
        frame['request']['input']['extra'] = {'large_id': 9007199254740993, 'text': '$(literal)\n'}
        _, encode = decode_request(SESSION, frame)
        allowed = encode(dict(action='choose', optionID='once'))['response']['response']
        self.assertEqual(allowed['updatedInput'], frame['request']['input'])
        allowed['updatedInput']['extra']['text'] = 'changed copy'
        self.assertEqual(frame['request']['input']['extra']['text'], '$(literal)\n')
        denied = encode(dict(action='choose', optionID='decline'))['response']['response']
        self.assertEqual(denied['behavior'], 'deny')
        self.assertTrue(denied['message'])
        self.assertNotIn('updatedInput', denied)

    def test_native_lifetime_survives_ten_minutes_and_disconnect_rejects_stale_response(self):
        now = [0]
        self.broker._clock = lambda: now[0]
        self.checkpoint([approval()])
        first = self.broker.pending()['requests'][0]
        now[0] = 3600
        self.assertEqual(self.broker.pending()['requests'][0]['requestID'], first['requestID'])
        self.adapter.disconnect()
        self.assertEqual(self.broker.pending()['requests'], [])
        self.assertIsNone(self.attention[-1])
        with self.assertRaises(BrokerError):
            self.submit(first)

    def test_cancellation_tombstone_prevents_a_stale_checkpoint_reopening_the_card(self):
        self.receive(dict(type='control_cancel_request', session_id=REMOTE, request_id='first'))
        self.checkpoint([approval()])
        self.assertEqual(self.broker.pending()['requests'], [])

    def test_client_cannot_inject_or_cancel_worker_owned_requests(self):
        self.checkpoint([])
        self.receive(approval(), 'client')
        self.assertEqual(self.broker.pending()['requests'], [])
        self.receive(approval())
        self.receive(dict(type='control_cancel_request', session_id=REMOTE, request_id='first'), 'client')
        self.assertEqual(len(self.broker.pending()['requests']), 1)

    def test_client_submission_is_not_native_consumption(self):
        self.checkpoint([approval()])
        self.receive(dict(type='control_response', session_id=REMOTE, response=dict(
            request_id='first', subtype='success', response={'behavior': 'allow'})), 'client')
        self.assertEqual(len(self.broker.pending()['requests']), 1)
        self.assertTrue(self.attention[-1])
        self.assertIn('first', self.adapter.confirming)
        self.receive(dict(type='control_cancel_request', session_id=REMOTE, request_id='first'))
        self.assertEqual(self.broker.pending()['requests'], [])
        self.assertFalse(self.adapter.confirming)

    def test_consumed_remote_answer_is_confirmed_even_without_native_cancel_event(self):
        self.checkpoint([approval()])
        self.submit(self.broker.pending()['requests'][0])
        wait_for(lambda: len(self.sent) == 2)
        self.assertTrue(self.attention[-1])
        self.adapter.next_checkpoint = 0
        self.adapter.refresh()
        wait_for(lambda: len(self.sent) == 3)
        rid = self.sent[-1]['request_id']
        self.receive(dict(type='control_response', session_id=REMOTE, response=dict(subtype='success',
            request_id=rid, response={}, pending_permission_requests=[], pending_user_dialog_requests=[])))
        self.assertFalse(self.attention[-1])
        self.assertFalse(self.adapter.confirming)
        self.assertEqual(sum(f['type'] == 'control_response' for f in self.sent), 1)

    def test_unconsumed_answer_is_represented_only_after_native_confirmation(self):
        self.checkpoint([approval()])
        first = self.broker.pending()['requests'][0]
        self.submit(first)
        wait_for(lambda: bool(self.adapter.confirming))
        self.assertEqual(self.broker.pending()['requests'], [])
        self.checkpoint([approval()])
        again = self.broker.pending()['requests'][0]
        self.assertNotEqual(first['requestID'], again['requestID'])
        self.assertEqual(sum(f['type'] == 'control_response' for f in self.sent), 1,
                         'The previous answer must not be sent again')
        self.assertTrue(self.attention[-1])

    def test_checkpoint_started_before_submission_cannot_reopen_that_answer(self):
        self.checkpoint([approval()])
        first = self.broker.pending()['requests'][0]
        self.adapter.initialize()
        checkpoint_id = self.sent[-1]['request_id']
        self.submit(first)
        wait_for(lambda: bool(self.adapter.confirming))
        self.receive(dict(type='control_response', session_id=REMOTE, response=dict(
            subtype='success', request_id=checkpoint_id, pending_permission_requests=[approval()],
            pending_user_dialog_requests=[])))
        self.assertEqual(self.broker.pending()['requests'], [])
        self.assertTrue(self.adapter.confirming)
        self.checkpoint([approval()])
        self.assertNotEqual(first['requestID'], self.broker.pending()['requests'][0]['requestID'])
        self.assertEqual(sum(f['type'] == 'control_response' for f in self.sent), 1)

    def test_closed_worker_cannot_republish_after_late_checkpoint(self):
        self.adapter.initialize()
        request_id = self.sent[-1]['request_id']
        self.adapter.close()
        self.receive(dict(type='control_response', session_id=REMOTE, response=dict(
            request_id=request_id, subtype='success', pending_permission_requests=[approval()],
            pending_user_dialog_requests=[])))
        self.assertEqual(self.broker.pending()['requests'], [])
        with self.assertRaises(OSError):
            self.adapter.initialize()

    def test_reconnect_checkpoint_clears_only_requests_the_owner_resolved(self):
        resolved = []
        self.adapter.resolution = lambda tools, pending: resolved.append((tools, pending))
        self.checkpoint([approval('first'), approval('sibling')])
        self.adapter.disconnect()
        self.checkpoint([approval('sibling')])
        self.assertEqual(resolved, [([('tool-first', 'Bash')], {'Bash'})])
        self.assertEqual(len(self.broker.pending()['requests']), 1)

    def test_checkpoint_timeout_is_checked_during_sse_keepalives(self):
        check = Mock(side_effect=[None, TimeoutError()])
        with self.assertRaises(TimeoutError):
            next(events(io.BytesIO(b': keepalive\n\n'), check))

    def test_review_mutation_cannot_reuse_older_remote_approval(self):
        self.checkpoint([approval()])
        first = self.broker.pending()['requests'][0]
        changed = approval(); changed['request']['input']['command'] = 'a different operation'
        self.receive(changed)
        self.assertEqual(self.broker.pending()['requests'], [])
        with self.assertRaises(BrokerError):
            self.submit(first)

    def test_release_does_not_decide_native_request_or_reopen_on_reconnect(self):
        self.checkpoint([approval()])
        self.broker.cancel_all()
        wait_for(lambda: 'first' in self.adapter.retired)
        self.assertEqual(len(self.sent), 1)
        self.adapter.disconnect()
        self.checkpoint([approval()])
        self.assertEqual(self.broker.pending()['requests'], [])

    def test_unsupported_dialogs_still_own_attention_without_blind_approval(self):
        self.checkpoint([approval(requires_user_interaction=True)])
        self.assertEqual(self.broker.pending()['requests'], [])
        self.assertTrue(self.attention[-1])
        self.assertIsNone(decode_request(SESSION, approval(requires_user_interaction=True)))
        raw = approval(suppress_always_allow_rule=True, permission_suggestions=[dict(type='setMode', mode='acceptEdits', destination='session')])
        public, _ = decode_request(SESSION, raw)
        self.assertEqual([o['id'] for o in public['responseOptions']], ['once', 'decline'])

    def test_native_question_preserves_entire_input_and_multiple_answers(self):
        raw = approval()
        original = dict(questions=[dict(question=f'Question {i}?', options=[dict(label='Blue', description='Choice')],
                       multiSelect=False) for i in range(2)], annotations={'preserve': True})
        raw['request'].update(tool_name='AskUserQuestion', input=original, requires_user_interaction=True)
        public, encode = decode_request(SESSION, raw)
        response = encode(dict(action='answer', answers=dict(q0=dict(selected=[0], text=''), q1=dict(selected=[], text='Green'))))
        self.assertEqual(response['response']['request_id'], 'first')
        updated = response['response']['response']['updatedInput']
        self.assertEqual(updated['questions'], original['questions'])
        self.assertEqual(updated['annotations'], {'preserve': True})
        self.assertEqual(updated['answers'], {'Question 0?': 'Blue', 'Question 1?': 'Green'})

    def test_question_option_previews_do_not_prevent_remote_answers(self):
        raw = approval()
        original = dict(questions=[dict(question='Which layout?', header='Layout', multiSelect=False,
            options=[dict(label='Compact', description='Less space', preview='<div>Compact</div>'),
                     dict(label='Spacious', description='More space', preview='```\nWide card\n```')])],
            annotations={'preserve': True})
        raw['request'].update(tool_name='AskUserQuestion', input=original, requires_user_interaction=True)
        self.checkpoint([raw])
        public = self.broker.pending()['requests'][0]
        self.assertEqual(public.get('contentVersion', 1), 1)
        self.assertEqual(public['questions'][0]['options'], [
            dict(label='Compact', description='Less space'), dict(label='Spacious', description='More space')])
        _, encode = decode_request(SESSION, raw)
        response = encode(dict(action='answer', answers=dict(q0=dict(selected=[1], text=''))))
        self.assertEqual(response['response']['request_id'], 'first')
        self.assertEqual(response['response']['response']['updatedInput'],
                         {**original, 'answers': {'Which layout?': 'Spacious'}})
        self.assertNotIn('answers', original)

    def test_missing_native_checkpoint_is_not_assumed_to_mean_no_pending_requests(self):
        self.adapter.initialize()
        with self.assertRaises(ValueError):
            self.receive(dict(type='control_response', session_id=REMOTE, response=dict(
                request_id=self.sent[-1]['request_id'], subtype='success', response={})))

    def test_http_transport_never_drives_agents_or_retries_an_uncertain_response(self):
        http = NativeHTTP(REMOTE, token_reader=lambda: 'private-token')
        http._open = Mock(side_effect=OSError('uncertain'))
        with self.assertRaises(OSError):
            http.send(dict(type='control_response', response=dict(request_id='first')))
        http._open.assert_called_once()
        with self.assertRaises(ValueError):
            http.send(dict(type='control_request', request={'subtype': 'set_permission_mode', 'mode': 'auto'}))

    def test_sse_decodes_multiline_data_and_does_not_log_ordinary_content(self):
        value = b': keepalive\n\nevent: client_event\ndata: {"source":"worker",\ndata: "sequence_num":1}\n\n'
        self.assertEqual(next(events(io.BytesIO(value))), ('client_event', dict(source='worker', sequence_num=1)))
        with self.assertRaises(ValueError):
            next(events(io.BytesIO(b'data: []\n\n')))

