"""Pairing ownership, legacy upgrade and removal through the public HTTP contract."""
import concurrent.futures
import http.client
import json
from pathlib import Path
import sqlite3
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
        body = {'invitation': invitation['invitation']}
        if device is not None: body['device'] = device
        status, paired = self.request('POST', '/v1/pair', body, previous)
        self.assertEqual(status, 200, paired)
        return paired

    def test_authenticated_repair_rotates_in_place_and_requires_new_push_registration(self):
        original = self.pair(self.device)
        self.store.push_device(original['credential'], {'deviceToken': 'ab' * 32, 'environment': 'development', 'mode': 'alert'})
        renamed = {**self.device, 'name': 'My phone'}
        again = self.pair(renamed, original['credential'])
        self.assertEqual(original['clientID'], again['clientID'])
        self.assertNotEqual(original['credential'], again['credential'])
        self.assertFalse(self.store.authorized(original['credential']))
        self.assertTrue(self.store.authorized(again['credential']))
        self.assertEqual(self.store.push_device(again['credential']), {'registered': False})
        self.assertEqual(len(self.store.clients()), 1)
        self.assertEqual(self.store.clients()[0]['name'], 'My phone')

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
        self.assertIsNone(rows[probe['clientID']]['name'])
        self.assertEqual(Store(self.store.path).clients(), self.store.clients())

    def test_existing_client_identifies_itself_without_repairing_or_merging_unknown_clients(self):
        own, old = self.pair(), self.pair()
        self.assertEqual(self.request('POST', '/v1/client', {'device': self.device}, own['credential'])[0], 200)
        self.assertEqual(self.request('POST', '/v1/client', {'device': self.device}, own['credential'])[0], 200)
        self.assertTrue(self.store.authorized(own['credential']))
        rows = self.store.clients()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['name'], self.device['name'])
        self.assertIsNone(rows[1]['name'])
        self.assertTrue(self.store.authorized(old['credential']))
        self.assertEqual(self.request('POST', '/v1/client', {'device': self.device}, old['credential'])[0], 409)

    def test_identification_requires_own_credential_and_valid_metadata(self):
        pair = self.pair()
        self.assertEqual(self.request('POST', '/v1/client', {'device': self.device})[0], 401)
        for device in (None, [], {}, {**self.device, 'installationID': 4}, {**self.device, 'name': 'x\nspoof'},
                       {**self.device, 'name': 'x' * 81}, {**self.device, 'platform': 'unknown'}):
            self.assertEqual(self.request('POST', '/v1/client', {'device': device}, pair['credential'])[0], 400)
        self.assertIsNone(self.store.clients()[0]['name'])
        self.assertEqual(self.request('POST', '/v1/client', {'device': self.device}, pair['credential'])[0], 200)
        changed = {**self.device, 'installationID': str(uuid.uuid4())}
        self.assertEqual(self.request('POST', '/v1/client', {'device': changed}, pair['credential'])[0], 409)

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
            self.assertEqual(db.execute('SELECT COUNT(*) FROM client_devices').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM push_devices').fetchone()[0], 1)
        fresh = self.pair(self.device, own['credential'])
        self.assertNotEqual(fresh['clientID'], own['clientID'])

    def test_rotating_or_revoking_a_client_closes_existing_stream(self):
        first = self.pair(self.device)
        for rotate in (True, False):
            connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
            connection.request('GET', '/v1/events', headers={'Authorization': 'Bearer ' + first['credential']})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            response.readline(); response.readline()
            if rotate: first = self.pair(self.device, first['credential'])
            else: self.assertEqual(self.request('DELETE', '/v1/client', token=first['credential'])[0], 200)
            self.assertEqual(response.readline(), b'')
            connection.close()

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

    def test_migration_keeps_legacy_credentials_unidentified(self):
        path = self.root / 'legacy.sqlite3'
        credential, client_id = 'old-secret', str(uuid.uuid4())
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE clients(id TEXT PRIMARY KEY,hash TEXT UNIQUE NOT NULL,created REAL NOT NULL)')
            db.execute('INSERT INTO clients VALUES (?,?,?)', (client_id, digest(credential), 10))
            self.assertIsNone(Store.client_list(db)[0]['name'])
        upgraded = Store(path)
        self.assertTrue(upgraded.authorized(credential))
        self.assertEqual(upgraded.clients(), [dict(id=client_id, pairedAt=10, lastContactAt=0, name=None, platform=None)])
