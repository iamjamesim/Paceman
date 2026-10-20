import json
import shlex
import socket
import struct
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock
from pathlib import Path

from service.codex_desktop import DesktopRequests, read_frame
from service.codex_requests import decode_request
from service.interactions import BrokerError, InteractionBroker


SESSION = "native-thread"


def command(rid=1, **params):
    return dict(id=rid, method="item/commandExecution/requestApproval", params=dict(
        threadId=SESSION, turnId="turn", itemId="item", kind="command", command="printf 'hello'",
        availableDecisions=["accept", "acceptForSession", "decline", "cancel"], **params))


def snapshot(requests, revision=1):
    return dict(type="broadcast", sourceClientId="native-owner", version=11,
                method="thread-stream-state-changed", params=dict(hostId="local", conversationId=SESSION,
                change=dict(type="snapshot", revision=revision,
                            conversationState=dict(id=SESSION, requests=requests, turns=[]))))


def submission(broker, request, **response):
    return dict(generation=broker.generation, requestID=request["requestID"], version=1,
                idempotencyKey="test-response", **response)


def wait_until(predicate):
    deadline = time.monotonic() + 3
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("condition did not complete")
        time.sleep(.01)


class DesktopRequestTests(unittest.TestCase):
    def setUp(self):
        self.broker = InteractionBroker()
        self.addCleanup(self.broker.close)
        self.adapter = DesktopRequests(self.broker, lambda: [SESSION])
        self.adapter.owners[SESSION] = "native-owner"
        self.addCleanup(self.adapter._reset)

    def test_local_answer_withdraws_exact_request_and_late_phone_answer_is_rejected(self):
        self.adapter._receive(snapshot([command(1), command(2)]))
        first, second = self.broker.pending()["requests"]
        self.adapter._receive(snapshot([command(2)], 2))
        self.assertEqual([r["requestID"] for r in self.broker.pending()["requests"]], [second["requestID"]])
        with self.assertRaises(BrokerError) as error:
            self.broker.submit(submission(self.broker, first, action="choose", optionID="decision-0"))
        self.assertEqual(error.exception.code, "stale_request")

    def test_remote_decision_preserves_id_type_owner_and_exact_decision(self):
        sent = []
        self.adapter._request = lambda method, params, **kw: sent.append((method, params, kw))
        self.adapter._receive(snapshot([command("1")]))
        pending = self.broker.pending()["requests"][0]
        receipt = self.broker.submit(submission(self.broker, pending, action="choose", optionID="decision-1"))
        wait_until(lambda: sent)
        self.assertEqual(sent, [("thread-follower-command-approval-decision", dict(
            conversationId=SESSION, requestId="1", decision="acceptForSession"), {"target": "native-owner", "connection": None})])
        self.assertEqual(self.broker.submit(submission(self.broker, pending, action="choose", optionID="decision-1")), receipt)
        self.adapter._receive(snapshot([command("1")], 2))
        self.assertEqual(self.broker.pending()["requests"], [])
        self.assertEqual(len(sent), 1)

    def test_connected_native_pending_does_not_expire_after_ten_minutes(self):
        now = [0]
        self.broker._clock = lambda: now[0]
        self.adapter._receive(snapshot([command()]))
        request = self.broker.pending()["requests"][0]
        now[0] += 3600
        self.assertEqual(self.broker.pending()["requests"][0]["requestID"], request["requestID"])
        self.adapter._reset()
        self.assertEqual(self.broker.pending()["requests"], [])

    def test_uncertain_response_reconnects_without_resending_the_decision(self):
        connection = Mock()
        self.adapter.connection = connection
        self.adapter._request = Mock(side_effect=OSError("response unavailable"))
        self.adapter._receive(snapshot([command()]))
        first = self.broker.pending()["requests"][0]
        self.broker.submit(submission(self.broker, first, action="choose", optionID="decision-0"))
        wait_until(lambda: connection.shutdown.called)
        connection.shutdown.assert_called_once_with(socket.SHUT_RDWR)
        self.adapter._request.assert_called_once()
        self.adapter._reset()
        self.adapter.owners[SESSION] = "native-owner"
        self.adapter._receive(snapshot([command()]))
        again = self.broker.pending()["requests"][0]
        self.assertNotEqual(first["requestID"], again["requestID"])
        self.adapter._request.assert_called_once()

    def test_access_change_releases_remote_card_without_deciding_native_request(self):
        sent = []
        self.adapter._request = lambda *args, **kw: sent.append(args)
        self.adapter._receive(snapshot([command()]))
        self.broker.cancel_all()
        wait_until(lambda: not self.adapter.pending)
        self.adapter._receive(snapshot([command()], 2))
        self.assertEqual(self.broker.pending()["requests"], [])
        self.assertEqual(sent, [])

    def test_stream_gap_and_unrecognized_version_cannot_leave_actionable_requests(self):
        self.adapter._receive(snapshot([command()]))
        update = snapshot([])
        update["params"]["change"] = dict(type="patches", baseRevision=0, revision=2, patches=[])
        with self.assertRaises(ValueError):
            self.adapter._receive(update)
        self.adapter._reset()
        self.assertEqual(self.broker.pending()["requests"], [])
        update = snapshot([command()]); update["version"] = 12
        self.adapter.owners[SESSION] = "native-owner"
        with self.assertRaises(ValueError):
            self.adapter._receive(update)

    def test_changed_native_request_invalidates_the_old_remote_choices(self):
        self.adapter._receive(snapshot([command()]))
        before = self.broker.pending()["requests"][0]
        changed = command(); changed["params"]["command"] = "a different action"
        self.adapter._receive(snapshot([changed], 2))
        self.assertEqual(self.broker.pending()["requests"], [])
        with self.assertRaises(BrokerError):
            self.broker.submit(submission(self.broker, before, action="choose", optionID="decision-0"))

    def test_only_owner_may_update_and_same_item_can_have_distinct_approval_callbacks(self):
        message = snapshot([command(1), command(2)])
        message["sourceClientId"] = "other-window"
        self.adapter._receive(message)
        self.assertEqual(self.broker.pending()["requests"], [])
        message["sourceClientId"] = "native-owner"
        self.adapter._receive(message)
        self.assertEqual(len(self.broker.pending()["requests"]), 2)
        self.adapter._receive(dict(type="broadcast", method="thread-stream-state-changed", version=11,
            sourceClientId="native-owner", params=dict(hostId="local", conversationId=SESSION,
                change=dict(type="patches", baseRevision=1, revision=2,
                            patches=[dict(op="remove", path=["requests", 0])]))))
        self.assertEqual(len(self.broker.pending()["requests"]), 1)

    def test_changed_file_review_invalidates_approval_even_with_unchanged_callback(self):
        request = dict(id=1, method="item/fileChange/requestApproval", params=dict(
            threadId=SESSION, turnId="turn", itemId="file"))
        message = snapshot([request])
        state = message["params"]["change"]["conversationState"]
        state["turns"] = [dict(turnId="turn", status="inProgress", items=[dict(
            id="file", type="fileChange", changes=[dict(path="a.py", diff="-old\n+new", kind=dict(type="update"))])])]
        self.adapter._receive(message)
        before = self.broker.pending()["requests"][0]
        state["turns"][0]["items"][0]["changes"][0]["diff"] = "-old\n+different"
        message["params"]["change"]["revision"] = 2
        self.adapter._receive(message)
        self.assertEqual(self.broker.pending()["requests"], [])
        with self.assertRaises(BrokerError):
            self.broker.submit(submission(self.broker, before, action="choose", optionID="decision-0"))

    def test_all_question_answers_are_mapped_without_replacing_the_question_batch(self):
        questions = [dict(id=f"q{i}", header="Choice", question=f"Question {i}?", isOther=True,
                         isSecret=False, options=[dict(label="First", description="Details")]) for i in range(2)]
        request = dict(id=4, method="item/tool/requestUserInput", params=dict(threadId=SESSION, questions=questions))
        public, encode = decode_request(SESSION, request)
        self.assertEqual(len(public["questions"]), 2)
        result = encode(dict(action="answer", answers=dict(q0=dict(selected=[0], text=""),
                                                          q1=dict(selected=[], text="Custom"))))
        self.assertEqual(result[1], dict(response=dict(answers=dict(q0=dict(answers=["First"]), q1=dict(answers=["Custom"])))))
        questions[0]["isSecret"] = True
        self.assertIsNone(decode_request(SESSION, request))
        questions[0]["isSecret"] = False
        questions[0]["isOther"] = False
        public, encode = decode_request(SESSION, request)
        self.assertEqual(public["contentVersion"], 3)
        self.assertEqual([q["allowsText"] for q in public["questions"]], [False, True])
        self.assertEqual(encode(dict(action="answer", answers=dict(q0=dict(selected=[0], text=""),
            q1=dict(selected=[], text="Custom"))))[1]["response"]["answers"]["q0"], {"answers": ["First"]})

    def test_policy_choices_are_exact_and_scope_is_visible(self):
        decisions = ["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["git", "status"]}},
                     {"applyNetworkPolicyAmendment": {"network_policy_amendment": {"host": "example.com", "action": "deny"}}}, "cancel"]
        raw = command(); raw["params"]["availableDecisions"] = decisions
        public, encode = decode_request(SESSION, raw)
        self.assertEqual(len(public["responseOptions"]), 4)
        self.assertIn('["git", "status"]', public["responseOptions"][1]["label"])
        self.assertIn("Always deny", public["responseOptions"][2]["label"])
        self.assertEqual(encode(dict(action="choose", optionID="decision-1"))[1]["decision"], decisions[1])
        raw["params"]["availableDecisions"].append({"futureDecision": {}})
        self.assertIsNone(decode_request(SESSION, raw))

    def test_mcp_approval_unpacks_actual_input_and_every_offered_persistence_choice(self):
        raw = dict(id=8, method='mcpServer/elicitation/request', params=dict(threadId=SESSION,
            mode='form', serverName='codex_apps', message='Allow edit page?', requestedSchema={'type': 'object', 'properties': {}},
            _meta=dict(codex_approval_kind='mcp_tool_call', connector_id='pages', tool_name='edit_page',
                tool_params={'page_id': 'page', 'operations': [{'op': 'replace', 'markdown': 'content'}]},
                tool_params_display=[{'name': 'summary', 'display_name': 'Changes', 'value': 'Replace paragraph'}],
                persist=['session', 'always'])))
        public, encode = decode_request(SESSION, raw)
        handle = self.broker.publish_live(public)
        approval = handle.public['approval']
        self.assertEqual(json.loads(approval['inputJSON']), raw['params']['_meta']['tool_params'])
        self.assertEqual(approval['displayText'], 'Changes:\nReplace paragraph')
        self.assertTrue(approval['hasAdditionalInput'])
        self.assertEqual(approval['toolName'], 'mcp__codex_apps__edit_page')
        self.assertEqual([o['id'] for o in public['responseOptions']], ['once', 'session', 'always', 'decline'])
        self.assertEqual(encode(dict(action='choose', optionID='session'))[1]['response'],
                         dict(action='accept', content={}, _meta={'persist': 'session'}))
        raw['params']['requestedSchema']['properties']['confirmation'] = {'type': 'boolean'}
        self.assertIsNone(decode_request(SESSION, raw))
        raw['params']['requestedSchema']['properties'] = {}
        raw['params']['_meta']['tool_params']['plan_token'] = 'bound-execution'
        self.assertIsNone(decode_request(SESSION, raw))

    def test_canonical_history_tracks_async_attention_without_retaining_conversation_text(self):
        attention = []
        self.adapter.attention = lambda _, turns: attention.append(turns.get('t') if turns else None)
        message = snapshot([])
        state = message['params']['change']['conversationState']
        state['turnHistory'] = dict(kind='canonical', history=dict(entitiesByKey={'turn:t': dict(
            turnId='t', status='inProgress', items=[dict(type='agentMessage', id='a', text='private prose',
                                                    questions=[{'title': 'Which?'}])])}))
        self.adapter._receive(message)
        self.assertTrue(attention[-1])
        stored = self.adapter.states[SESSION][1]
        self.assertNotIn('private prose', json.dumps(stored))
        turn = state['turnHistory']['history']['entitiesByKey']['turn:t']
        turn['items'].append(dict(type='steeringUserMessage', status='pending', input=[dict(type='text', text=
            '<send_user_message_question_reply>' + json.dumps([dict(questionItemId='["request_user_input_async","a",0]',
                question='Which?', answer='First')]) + '</send_user_message_question_reply>')]))
        self.adapter._receive(message)
        self.assertTrue(attention[-1], 'Unaccepted steering cannot resolve a question')
        turn['items'][-1]['status'] = 'accepted'
        self.adapter._receive(message)
        self.assertFalse(attention[-1])

    def test_async_questions_queue_individually_and_native_answer_withdraws_only_one(self):
        message = snapshot([])
        state = message['params']['change']['conversationState']
        turn = dict(turnId='t', status='inProgress', items=[dict(type='agentMessage', id='a', questions=[
            dict(title='First question?', options=['Yes', 'No']), dict(title='Second question?', options=['A', 'B'])])])
        state['turns'] = [turn]
        self.adapter._receive(message)
        requests = self.broker.pending()['requests']
        self.assertEqual([r['questions'][0]['prompt'] for r in requests], ['First question?', 'Second question?'])
        reply = '<send_user_message_question_reply>' + json.dumps([dict(
            questionItemId='["request_user_input_async","a",0]', question='First question?', answer='Yes')]) + '</send_user_message_question_reply>'
        turn['items'].append(dict(type='steeringUserMessage', status='accepted', input=[dict(type='text', text=reply)]))
        self.adapter._receive(message)
        remaining = self.broker.pending()['requests']
        self.assertEqual([r['requestID'] for r in remaining], [requests[1]['requestID']])
        with self.assertRaises(BrokerError):
            self.broker.submit(submission(self.broker, requests[0], action='answer', answers={'answer': dict(selected=[1], text='')}))

    def test_async_answer_uses_normal_native_reply_and_never_fabricates_a_tool_denial(self):
        sent = []
        self.adapter._request = lambda method, params, **kw: sent.append((method, params, kw))
        message = snapshot([])
        message['params']['change']['conversationState']['turns'] = [dict(turnId='t', status='inProgress', items=[
            dict(type='agentMessage', id='a', questions=[dict(title='Which?', options=['Blue', 'Green'])])])]
        self.adapter._receive(message)
        request = self.broker.pending()['requests'][0]
        self.broker.submit(submission(self.broker, request, action='answer', answers={'answer': dict(selected=[1], text='')}))
        wait_until(lambda: sent)
        method, params, target = sent[0]
        self.assertEqual(method, 'thread-follower-steer-turn')
        self.assertNotIn('requestId', params)
        self.assertEqual(target['target'], 'native-owner')
        text = params['input'][0]['text']
        self.assertEqual(json.loads(text[len('<send_user_message_question_reply>'):-len('</send_user_message_question_reply>')]),
            [dict(questionItemId='["request_user_input_async","a",0]', question='Which?', answer='Green')])
        self.assertNotIn('permissionDecision', text)
        self.assertEqual(params['input'][0]['text_elements'], [])

    def test_file_approval_needs_actual_patch_and_stdin_never_shows_parent_as_action(self):
        request = dict(id=1, method="item/fileChange/requestApproval", params=dict(threadId=SESSION, itemId="file"))
        self.assertIsNone(decode_request(SESSION, request))
        decoded = decode_request(SESSION, request, [dict(id="file", type="fileChange", changes=[
            dict(path="a.py", diff="-old\n+new", kind=dict(type="update"))])])
        handle = self.broker.publish_live(decoded[0])
        self.assertEqual(handle.public["approval"]["action"]["text"], "a.py\n-old\n+new")
        raw = command(); raw["params"]["kind"] = "writeStdin"
        self.assertIsNone(decode_request(SESSION, raw))

    def test_native_terminal_approval_decodes_exact_input_without_changing_reply(self):
        for text, operation in [('\x03\x03', 'interrupt'), ('', 'poll'),
                                ('say "hi"; $(literal)\n日本語\\\'', 'write')]:
            with self.subTest(text=text):
                raw = command()
                raw['params'].update(kind='writeStdin', approvalId='callback',
                    command=shlex.join(['write_stdin', '--session-id', '35467', text]),
                    availableDecisions=['accept', 'cancel'])
                public, encode = decode_request(SESSION, raw, [dict(type='commandExecution', id='item',
                    processId='35467', command='xcodebuild test')])
                handle = self.broker.publish_live(public)
                action = handle.public['approval']['action']
                self.assertEqual(action['text'], text)
                self.assertEqual(action['operation'], operation)
                self.assertEqual(action['terminalSessionID'], '35467')
                self.assertEqual(action['parentCommand'], 'xcodebuild test')
                self.assertEqual(json.loads(handle.public['approval']['inputJSON']), raw['params'])
                self.assertEqual(encode(dict(action='choose', optionID='decision-0')),
                    ('thread-follower-command-approval-decision', {'decision': 'accept'}))
                self.broker.withdraw(handle)

    def test_native_terminal_format_does_not_guess_unknown_argv_or_parent(self):
        for value in ['write_stdin --session-id 3', 'write_stdin --session-id x text',
                      'write_stdin --session-id 3 text extra', 'write_stdin --session-id 3 \"unterminated',
                      'python3 -c parent']:
            raw = command(); raw['params'].update(kind='writeStdin', command=value)
            self.assertIsNone(decode_request(SESSION, raw))
        raw = command()
        raw['params'].update(kind='writeStdin', command="write_stdin --session-id 3 text")
        public, _ = decode_request(SESSION, raw, [dict(type='commandExecution', id='item',
            processId='4', command='different parent')])
        handle = self.broker.publish_live(public)
        self.assertNotIn('parentCommand', handle.public['approval']['action'])


class NativeSocketTests(unittest.TestCase):
    def test_real_framing_attach_is_follower_only_and_disconnect_withdraws(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "ipc.sock"
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(path)); server.listen(1)
                observed = []
                finished = threading.Event()

                def send(connection, value):
                    data = json.dumps(value).encode()
                    connection.sendall(struct.pack("<I", len(data)) + data)

                def native():
                    with server.accept()[0] as connection:
                        connection.settimeout(5)
                        for method, result in [("initialize", dict(clientId="paceman-client")),
                                               ("thread-owner-discovery", {})]:
                            call = read_frame(connection); observed.append(call)
                            self.assertEqual(call["method"], method)
                            send(connection, dict(type="response", requestId=call["requestId"], resultType="success",
                                method=method, handledByClientId="native-owner", result=result))
                        observed.append(read_frame(connection))
                        send(connection, snapshot([command()]))
                        finished.wait(3)
                thread = threading.Thread(target=native)
                thread.start()
                broker = InteractionBroker()
                with DesktopRequests(broker, lambda: [SESSION], path=path):
                    wait_until(lambda: broker.pending()["requests"])
                    self.assertEqual(observed[0]["params"]["clientType"], "paceman")
                    self.assertEqual(observed[2]["params"]["following"], True)
                    self.assertEqual([m["method"] for m in observed], ["initialize", "thread-owner-discovery", "thread-stream-following-changed"])
                    finished.set()
                    wait_until(lambda: not broker.pending()["requests"])
                thread.join(3)
                broker.close()


if __name__ == "__main__":
    unittest.main()
