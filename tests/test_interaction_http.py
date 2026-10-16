"""Paired HTTP to live response-hook tests; no installed agent is touched."""
import http.client
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

from service.hub import Server, Store
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
        self.broker = InteractionBroker()
        self.listener = self.enterContext(ResponseListener(self.broker, root / 'input.sock'))
        self.server = self.enterContext(Server(('127.0.0.1', 0), self.store, interactions=self.broker))
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown()
        self.thread.join(2)

    def call(self, method, path, payload=None, authorized=True):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        self.addCleanup(connection.close)
        headers = {'Authorization': 'Bearer ' + self.client['credential']} if authorized else {}
        body = json.dumps(payload) if payload is not None else None
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read())

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
