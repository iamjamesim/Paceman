"""Identified pairing and removal through the public HTTP contract."""
import concurrent.futures
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid

from service.hub import Server, Store, digest
from service.status import DesktopStatus


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store(self.root / 'hub.sqlite3')
        self.status = DesktopStatus(self.root / 'status.json', self.store)
        self.server = Server(('127.0.0.1', 0), self.store, desktop_status=self.status)
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=.01), daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)
        self.device = dict(installationID=str(uuid.uuid4()), name='Alex’s iPhone', platform='ios')

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, method, path, body=None, token=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        headers = {'Authorization': 'Bearer ' + token} if token else {}
        connection.request(method, path, json.dumps(body) if body is not None else None, headers)
        response = connection.getresponse()
        result = response.status, json.loads(response.read())
        connection.close()
        return result

    def pair(self, device=None, previous=None):
        invitation = self.store.invite('https://test.example')
        body = {'invitation': invitation['invitation'], 'device': device or {
            **self.device, 'installationID': str(uuid.uuid4())}}
        status, paired = self.request('POST', '/v1/pair', body, previous)
        self.assertEqual(status, 200, paired)
        return paired

    def test_authenticated_repair_rotates_in_place_and_requires_new_push_registration(self):
        original = self.pair(self.device)
        self.store.push_device(original['credential'], {'deviceToken': 'ab' * 32, 'environment': 'development', 'mode': 'alert'})
        self.store.watch_push_device(original['credential'], {'deviceToken': 'cd' * 32, 'environment': 'development'})
        renamed = {**self.device, 'name': 'My phone'}
        again = self.pair(renamed, original['credential'])
        self.assertEqual(original['clientID'], again['clientID'])
        self.assertNotEqual(original['credential'], again['credential'])
        self.assertFalse(self.store.authorized(original['credential']))
        self.assertTrue(self.store.authorized(again['credential']))
        self.assertEqual(self.store.push_device(again['credential']), {'registered': False})
        self.assertEqual(self.store.watch_push_device(again['credential']), {'registered': False})
        self.assertEqual(len(self.store.clients()), 1)
        self.assertEqual(self.store.clients()[0]['name'], 'My phone')

    def test_watch_push_registration_requires_pairing_and_is_idempotent(self):
        paired = self.pair(self.device)
        payload = {'deviceToken': 'ab' * 32, 'environment': 'development'}
        self.assertEqual(self.request('POST', '/v1/watch-push', payload)[0], 401)
        self.assertEqual(self.request('POST', '/v1/watch-push', payload, paired['credential']),
                         (200, {'registered': True}))
        self.assertEqual(self.request('POST', '/v1/watch-push', payload, paired['credential']),
                         (200, {'registered': True}))
        self.assertEqual(self.request('POST', '/v1/watch-push',
                                      {**payload, 'deviceToken': 'not-a-token'}, paired['credential'])[0], 400)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM watch_push_devices').fetchone()[0], 1)

    def test_claiming_an_installation_cannot_take_over_its_pairing_or_consume_code(self):
        first, attacker = self.pair(self.device), self.pair()
        invitation = self.store.invite('https://test.example')
        body = {'invitation': invitation['invitation'], 'device': self.device}
        for token in (None, 'invalid', attacker['credential']):
            self.assertEqual(self.request('POST', '/v1/pair', body, token)[0], 409)
            self.assertTrue(self.store.authorized(first['credential']))
        self.assertEqual(self.request('POST', '/v1/pair', body, first['credential'])[0], 200)
        self.assertTrue(self.store.authorized(attacker['credential']))

    def test_two_installations_with_same_name_stay_distinct_and_contacts_are_independent(self):
        first = self.pair(self.device)
        second = self.pair({**self.device, 'installationID': str(uuid.uuid4())})
        probe = self.pair()
        for pair in (second, probe):
            self.assertEqual(self.request('GET', '/v1/snapshot', token=pair['credential'])[0], 200)
        deadline = time.monotonic() + 2
        while not self.store.clients()[2]['lastContactAt'] and time.monotonic() < deadline:
            time.sleep(.01)
        rows = {row['id']: row for row in self.store.clients()}
        self.assertEqual(rows[first['clientID']]['lastContactAt'], 0)
        self.assertGreater(rows[second['clientID']]['lastContactAt'], 0)
        self.assertEqual(rows[probe['clientID']]['name'], self.device['name'])
        self.assertEqual(Store(self.store.path).clients(), self.store.clients())

    def test_pairing_requires_valid_identity_and_has_no_identification_endpoint(self):
        for device in (None, [], {}, {**self.device, 'installationID': 4}, {**self.device, 'name': 'x\nspoof'},
                       {**self.device, 'name': 'x' * 81}, {**self.device, 'platform': 'unknown'}):
            invitation = self.store.invite('https://test.example')
            self.assertEqual(self.request('POST', '/v1/pair', {'invitation': invitation['invitation'], 'device': device})[0], 400)
        self.assertEqual(self.request('POST', '/v1/client', {'device': self.device})[0], 404)
        self.assertEqual(self.store.clients(), [])

    def test_source_rejects_unidentified_client_data(self):
        with self.store.connect() as db:
            db.execute("INSERT INTO clients(id,hash,created) VALUES (?,?,?)",
                       (str(uuid.uuid4()), digest("unidentified"), 1))
        with self.assertRaisesRegex(ValueError, "Unidentified client data is unsupported"):
            Store(self.store.path)

    def test_self_removal_only_revokes_caller_and_clears_push_and_identity(self):
        own, other = self.pair(self.device), self.pair()
        for pair in (own, other):
            self.store.push_device(pair['credential'], {'deviceToken': 'ab' * 32, 'environment': 'development', 'mode': 'alert'})
        self.assertEqual(self.request('DELETE', '/v1/client')[0], 401)
        self.assertEqual(self.request('DELETE', '/v1/client', {'clientID': other['clientID']}, own['credential'])[0], 200)
        self.assertEqual(self.request('DELETE', '/v1/client', token=own['credential'])[0], 401)
        self.assertEqual(self.request('GET', '/v1/snapshot', token=own['credential'])[0], 401)
        self.assertTrue(self.store.authorized(other['credential']))
        self.assertTrue(self.store.push_device(other['credential'])['registered'])
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM client_devices').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM push_devices').fetchone()[0], 1)
        fresh = self.pair(self.device, own['credential'])
        self.assertNotEqual(fresh['clientID'], own['clientID'])

    def test_rotating_or_revoking_a_client_rejects_old_snapshot_access(self):
        first = self.pair(self.device)
        for rotate in (True, False):
            old_token = first['credential']
            self.assertEqual(self.request('GET', '/v1/snapshot', token=old_token)[0], 200)
            if rotate:
                first = self.pair(self.device, old_token)
            else:
                self.assertEqual(self.request('DELETE', '/v1/client', token=old_token)[0], 200)
            self.assertEqual(self.request('GET', '/v1/snapshot', token=old_token)[0], 401)

    def test_concurrent_first_pairing_does_not_create_duplicate_installations(self):
        invitations = [self.store.invite('https://test.example')['invitation'] for _ in range(2)]
        def redeem(token):
            return self.request('POST', '/v1/pair', {'invitation': token, 'device': self.device})[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(redeem, invitations)), [200, 409])
        self.assertEqual(len(self.store.clients()), 1)

    def test_status_and_snapshot_never_export_credentials_or_installation_ids(self):
        paired = self.pair(self.device)
        self.status.publish(force=True)
        public = self.status.path.read_text() + json.dumps(self.store.snapshot())
        for secret in (paired['credential'], digest(paired['credential']), self.device['installationID']):
            self.assertNotIn(secret, public)
        self.assertEqual(json.loads(self.status.path.read_text())['clients'][0]['name'], self.device['name'])
        self.assertNotIn('clients', self.store.snapshot())
