"""Paired HTTP to live response-hook tests; no installed agent is touched."""
import http.client
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from service import hub
from service.hub import Server, Store
from service.diagnostics import DeliveryDiagnostics
from service.interactions import InteractionBroker, ResponseListener
from macos.interaction_hook import normalize, native_response
from tests.identity import device


class InteractionHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp' if Path('/private/tmp').exists() else None)
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.store = Store(root / 'source.db')
        self.client = self.store.redeem(self.store.invite('https://example.test')['invitation'], device=device())
        self.diagnostics = DeliveryDiagnostics(root / 'delivery-diagnostics.jsonl')
        self.broker = InteractionBroker(diagnostics=self.diagnostics)
        self.listener = self.enterContext(ResponseListener(self.broker, root / 'input.sock'))
        self.server = self.enterContext(Server(('127.0.0.1', 0), self.store, interactions=self.broker,
                                              diagnostics=self.diagnostics))
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown()
        self.thread.join(2)

    def call(self, method, path, payload=None, authorized=True, trace_id=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        self.addCleanup(connection.close)
        headers = {'Authorization': 'Bearer ' + self.client['credential']} if authorized else {}
        if trace_id is not None:
            headers['X-Paceman-Trace-ID'] = trace_id
        body = json.dumps(payload) if payload is not None else None
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read())

    def completed_replies(self):
        replies = queue.Queue()
        record = self.diagnostics.record

        def record_completed(stage, **fields):
            record(stage, **fields)
            if stage == 'http_replied':
                replies.put(None)

        self.enterContext(patch.object(self.diagnostics, 'record', side_effect=record_completed))
        return replies

    def test_trace_distinguishes_empty_expired_inbox_from_failed_fetch(self):
        replies = self.completed_replies()
        self.hook()
        trace = 'c9b86b49-fbd9-4acf-90b7-461265034bae'
        status, before = self.call('GET', '/v1/interactions', trace_id=trace)
        replies.get(timeout=2)
        self.assertEqual(status, 200)
        self.assertEqual(len(before['requests']), 1)
        self.broker._clock = lambda: time.monotonic() + 601
        status, after = self.call('GET', '/v1/interactions', trace_id=trace)
        replies.get(timeout=2)
        self.assertEqual((status, after['requests']), (200, []))
        entries = [json.loads(line) for line in self.diagnostics.path.read_text().splitlines()]
        releases = [e for e in entries if e['stage'] == 'request_released']
        self.assertEqual([e['reason'] for e in releases], ['deadline'])
        replies = [e for e in entries if e['stage'] == 'http_replied']
        self.assertEqual([e['pendingCount'] for e in replies], [1, 0])
        self.assertTrue(all(e['traceID'] == trace and e['httpStatus'] == 200 for e in replies))
        encoded = json.dumps(entries)
        for private in ['echo fixture', 'local-fixture', self.client['credential'], 'Allow Bash']:
            self.assertNotIn(private, encoded)

    def test_unauthorized_fetch_logs_status_without_credential(self):
        replies = self.completed_replies()
        status, _ = self.call('GET', '/v1/snapshot', authorized=False, trace_id='private invalid value')
        replies.get(timeout=2)
        self.assertEqual(status, 401)
        entries = [json.loads(line) for line in self.diagnostics.path.read_text().splitlines()]
        self.assertEqual(entries[-1]['httpStatus'], 401)
        self.assertNotIn('traceID', entries[-1])

    def test_mac_startup_advertises_responses_without_extra_configuration(self):
        root = Path(self.temp.name) / 'normal-install'
        root.mkdir(mode=0o700)
        store = Store(root / 'data/hub.sqlite3')
        paired = store.redeem(store.invite('https://example.test')['invitation'], device=device())

        def verify(server, **_):
            self.assertIsNotNone(server.interactions)
            self.assertTrue((root / 'interaction.sock').is_socket())
            server.daemon_threads = False  # Teardown joins the real HTTP handler.
            receiver = threading.Thread(target=server.handle_request, daemon=True)
            receiver.start()
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)
            try:
                connection.request('GET', '/v1/snapshot', headers={'Authorization': 'Bearer ' + paired['credential']})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertTrue(json.loads(response.read())['interactionsEnabled'])
            finally:
                connection.close()
                receiver.join(2)
            self.assertFalse(receiver.is_alive())

        with patch.object(sys, 'argv', ['paceman-source', '--data-dir', str(root / 'data'),
                'serve', '--source', 'macos', '--port', '0']), \
                patch.object(Server, 'serve_forever', autospec=True, side_effect=verify) as serve, \
                patch('builtins.print'):
            hub.main()
        serve.assert_called_once()
        self.assertFalse((root / 'interaction.sock').exists())

    def hook(self, provider='codex', question=False):
        original = {'hook_event_name': 'PreToolUse' if question else 'PermissionRequest',
                    'session_id': 'local-fixture', 'cwd': '/Projects/example',
                    'tool_name': 'AskUserQuestion' if question else 'Bash',
                    'tool_input': {'questions': [{'question': 'Which approach?', 'multiSelect': False,
                        'options': [{'label': 'Small change', 'description': 'Keep the layout.'},
                                    {'label': 'New layout', 'description': 'Explore more.'}]}]}
                        if question else {'command': 'echo fixture'}}
        request = normalize(provider, original)
        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(peer.close)
        peer.settimeout(2); peer.connect(str(self.listener.path))
        peer.sendall(json.dumps({'request': request, 'timeoutSeconds': 60}).encode() + b'\n')
        deadline = time.monotonic() + 2
        while not self.broker.pending()['requests']:
            if time.monotonic() > deadline: self.fail('Hook was not published')
            time.sleep(.005)
        return peer, original, request

    def answer(self, listing, action='allowOnce', **extra):
        return dict(generation=listing['generation'], requestID=listing['requests'][0]['requestID'],
                    version=1, idempotencyKey='fixture-retry', action=action, **extra)

    def test_installed_hook_process_consumes_http_response_and_emits_native_decision(self):
        for provider, action in (('codex', 'allowOnce'), ('codex', 'deny'), ('codex', 'answer'),
                                 ('claude', 'allowOnce'), ('claude', 'deny'), ('claude', 'answer')):
            with self.subTest(provider=provider, action=action):
                is_question = action == 'answer'
                original = {'session_id': 'process-fixture', 'cwd': '/Projects/fixture',
                            'hook_event_name': 'PreToolUse' if is_question else 'PermissionRequest',
                            'tool_name': 'AskUserQuestion' if is_question else 'Bash',
                            'tool_input': {'questions': [{'question': 'Which approach?', 'multiSelect': False,
                                'options': [{'label': 'Small', 'description': 'Keep it simple'},
                                            {'label': 'Large', 'description': 'More detail'}]}]}
                                if is_question else {'command': 'echo fixture'}}
                if is_question and provider == 'codex':
                    original['tool_name'] = 'request_user_input'
                    original['tool_input']['questions'][0]['id'] = 'approach'
                process = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve().parents[1]
                    / 'macos/interaction_hook.py'), '--provider', provider], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    env=dict(os.environ, PACEMAN_INTERACTION_SOCKET=str(self.listener.path)))
                try:
                    process.stdin.write(json.dumps(original).encode())
                    process.stdin.close()
                    deadline = time.monotonic() + 3
                    listing = self.call('GET', '/v1/interactions')[1]
                    while not listing['requests']:
                        if time.monotonic() >= deadline:
                            self.fail('Executable hook did not publish its request')
                        time.sleep(.01)
                        listing = self.call('GET', '/v1/interactions')[1]
                    self.assertGreater(listing['requests'][0]['remainingSeconds'], 590)
                    extra = {'answers': {'q0': {'selected': [0], 'text': ''}}} if is_question else {}
                    self.assertEqual(self.call('POST', '/v1/interactions',
                        self.answer(listing, action, **extra))[0], 200)
                    process.wait(3)
                    output = json.loads(process.stdout.read())['hookSpecificOutput']
                    self.assertEqual(process.stderr.read(), b'')
                    self.assertEqual(process.returncode, 0)
                    if is_question and provider == 'codex':
                        self.assertEqual(output['permissionDecision'], 'deny')
                        feedback = json.loads(output['permissionDecisionReason'].split('\n', 1)[1])
                        self.assertEqual(feedback, {'approach': {'question': 'Which approach?', 'answer': 'Small'}})
                    elif is_question:
                        self.assertEqual(output['updatedInput']['answers'], {'Which approach?': 'Small'})
                    else:
                        self.assertEqual(output['decision']['behavior'], 'allow' if action == 'allowOnce' else 'deny')
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(3)
                    process.stdout.close()
                    process.stderr.close()

    def test_authorized_approval_round_trip_and_idempotent_retry(self):
        peer, original, request = self.hook()
        status, listing = self.call('GET', '/v1/interactions')
        self.assertEqual(status, 200)
        self.assertEqual(listing['sourceID'], self.client['sourceID'])
        self.assertEqual(listing['requests'][0]['detail'], request['detail'])
        payload = self.answer(listing)
        status, receipt = self.call('POST', '/v1/interactions', payload)
        self.assertEqual((status, receipt['status']), (200, 'submitted'))
        reply = json.loads(peer.recv(65536))
        self.assertEqual(native_response('codex', original, request, reply)['hookSpecificOutput']['decision'], {'behavior': 'allow'})
        self.assertEqual(self.call('POST', '/v1/interactions', payload), (200, receipt))
        self.assertEqual(self.call('GET', '/v1/interactions')[1]['requests'], [])
        snapshot = self.call('GET', '/v1/snapshot')[1]
        self.assertTrue(snapshot['interactionsEnabled'])
        self.assertNotIn('echo fixture', json.dumps(snapshot))
        with self.store.connect() as db:
            self.assertNotIn('echo fixture', '\n'.join(db.iterdump()))

    def test_claude_question_round_trip_preserves_exact_original(self):
        peer, original, request = self.hook('claude', question=True)
        listing = self.call('GET', '/v1/interactions')[1]
        payload = self.answer(listing, 'answer', answers={'q0': {'selected': [], 'text': 'Keep it simple — 日本語'}})
        self.assertEqual(self.call('POST', '/v1/interactions', payload)[0], 200)
        result = native_response('claude', original, request, json.loads(peer.recv(65536)))
        updated = result['hookSpecificOutput']['updatedInput']
        self.assertEqual(updated['questions'], original['tool_input']['questions'])
        self.assertEqual(updated['answers'], {'Which approach?': 'Keep it simple — 日本語'})

    def test_auth_and_revocation_release_live_hook(self):
        peer, _, _ = self.hook()
        listing = self.call('GET', '/v1/interactions')[1]
        payload = self.answer(listing)
        self.assertEqual(self.call('GET', '/v1/interactions', authorized=False)[0], 401)
        self.assertEqual(self.call('POST', '/v1/interactions', payload, authorized=False)[0], 401)
        self.assertEqual(self.call('DELETE', '/v1/client')[0], 200)
        self.assertEqual(json.loads(peer.recv(65536)), {'action': 'release'})
        self.assertEqual(self.call('POST', '/v1/interactions', payload)[0], 401)

    def test_revocation_and_submission_have_a_definite_order(self):
        peer, _, _ = self.hook()
        listing = self.call('GET', '/v1/interactions')[1]
        entered, finish, revoked = threading.Event(), threading.Event(), threading.Event()
        original_submit = self.broker.submit
        def held_submit(payload):
            entered.set()
            if not finish.wait(2): raise RuntimeError('test timeout')
            return original_submit(payload)
        self.broker.submit = held_submit
        results = []
        sender = threading.Thread(target=lambda: results.append(
            self.call('POST', '/v1/interactions', self.answer(listing))))
        sender.start()
        self.assertTrue(entered.wait(2))
        def revoke():
            self.store.revoke(self.client['clientID'])
            revoked.set()
        remover = threading.Thread(target=revoke)
        remover.start()
        try:
            self.assertFalse(revoked.wait(.05))
        finally:
            finish.set()
            sender.join(2); remover.join(2)
        self.assertTrue(revoked.is_set())
        self.assertEqual(results[0][0], 200)
        self.assertEqual(json.loads(peer.recv(65536)), {'action': 'allowOnce'})
        self.assertEqual(self.call('POST', '/v1/interactions', self.answer(listing))[0], 401)

    def test_disconnected_hook_rejects_stale_response(self):
        peer, _, _ = self.hook()
        listing = self.call('GET', '/v1/interactions')[1]
        peer.close()
        deadline = time.monotonic() + 2
        while self.broker.pending()['requests']:
            if time.monotonic() > deadline: self.fail('Hook not invalidated')
            time.sleep(.005)
        self.assertEqual(self.call('POST', '/v1/interactions', self.answer(listing))[0], 409)

    def test_default_server_does_not_expose_interaction_content(self):
        self.server.interactions = None
        self.assertEqual(self.call('GET', '/v1/interactions')[0], 404)
        self.assertNotIn('interactionsEnabled', self.call('GET', '/v1/snapshot')[1])
