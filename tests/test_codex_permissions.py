from copy import deepcopy
from pathlib import Path
import json
import time
import unittest
from unittest.mock import Mock

from service.codex_daemon import DaemonRequests
from service.codex_desktop import DesktopRequests
from service.codex_requests import decode_request
from service.interactions import BrokerError, InteractionBroker


def request(rid='permission-callback'):
    fixture = json.loads((Path(__file__).parent / 'fixtures/codex-permissions-inventory.json').read_text())
    raw = fixture['request']
    raw['id'] = rid
    raw['params']['cwd'] = str(Path.home())
    filesystem = raw['params']['permissions']['fileSystem']
    for access in ('read', 'write'):
        filesystem[access] = [str(Path.home() / 'Desktop')]
    for entry in filesystem['entries']:
        entry['path']['path'] = str(Path.home() / 'Desktop')
    return raw


def wait_for(predicate):
    deadline = time.monotonic() + 2
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError('response did not complete')
        time.sleep(.005)


class PermissionRequestTests(unittest.TestCase):
    def adapter(self, desktop):
        self.broker = InteractionBroker()
        self.addCleanup(self.broker.close)
        if desktop:
            self.native = DesktopRequests(self.broker, lambda: ['session'])
            self.native.owners['session'] = 'owner'
            self.native.connection = Mock()
            self.native._request = Mock()
        else:
            self.native = DaemonRequests(self.broker, lambda: {'session': 'turn'})
            self.native.connection = Mock()
            self.native.joined['session'] = 'turn'
            self.native.ready.add('session')
            self.native.items['session'] = {}
        self.addCleanup(self.native._reset)
        return self.native

    def receive(self, raw, desktop):
        if desktop:
            self.native._sync('session', dict(requests=[raw] if raw else [], turns=[]))
        elif raw:
            self.native.receive(raw)
        else:
            self.native.receive(dict(method='serverRequest/resolved',
                                     params=dict(threadId='session', requestId='permission-callback')))

    def submit(self, pending, option):
        return self.broker.submit(dict(generation=self.broker.generation, version=1,
            requestID=pending['requestID'], idempotencyKey='test-' + option,
            action='choose', optionID=option))

    def test_exact_native_responses_on_both_transports_and_owner_confirmation(self):
        for desktop in (True, False):
            for option in (('turn', 'deny') if desktop else ('turn', 'session', 'deny')):
                with self.subTest(desktop=desktop, option=option):
                    adapter = self.adapter(desktop)
                    raw = request()
                    self.receive(raw, desktop)
                    pending, = self.broker.pending()['requests']
                    self.assertEqual(pending['approval']['displayText'],
                                     'View and edit contents:\n' + str(Path.home() / 'Desktop'))
                    self.assertEqual(pending['approval']['reason'], raw['params']['reason'])
                    receipt = self.submit(pending, option)
                    result = dict(permissions={} if option == 'deny' else raw['params']['permissions'],
                                  scope='session' if option == 'session' else 'turn')
                    if desktop:
                        wait_for(lambda: adapter._request.called)
                        adapter._request.assert_called_once_with(
                            'thread-follower-permissions-request-approval-response',
                            dict(conversationId='session', requestId=raw['id'], response=result),
                            target='owner', connection=adapter.connection)
                    else:
                        wait_for(lambda: adapter.connection.send.called)
                        adapter.connection.send.assert_called_once_with(dict(id=raw['id'], result=result))
                    self.assertEqual(self.submit(pending, option), receipt)
                    self.assertEqual(self.broker.pending()['awaitingRequestIDs'], [pending['requestID']])
                    self.receive(None, desktop)
                    self.assertEqual(self.broker.pending()['awaitingRequestIDs'], [])
                    adapter._reset()
                    self.broker.close()

    def test_changed_scope_withdraws_old_card_and_preserves_sibling(self):
        adapter = self.adapter(True)
        first, sibling = request(), request(42)
        adapter._sync('session', dict(requests=[first, sibling], turns=[]))
        old, other = self.broker.pending()['requests']
        first['params']['permissions']['fileSystem']['entries'][1]['path']['path'] += '/Another folder'
        adapter._sync('session', dict(requests=[first, sibling], turns=[]))
        self.assertEqual([p['requestID'] for p in self.broker.pending()['requests']], [other['requestID']])
        with self.assertRaises(BrokerError):
            self.submit(old, 'turn')
        adapter._request.assert_not_called()
        adapter._reset()
        with self.assertRaises(BrokerError):
            self.submit(other, 'turn')

    def test_unsupported_or_ambiguous_permissions_remain_native(self):
        original = request()
        mutations = [
            lambda p: p.update(environmentId='remote'),
            lambda p: p.update(futureScope=True),
            lambda p: p['permissions'].update(network=dict(enabled=True)),
            lambda p: p['permissions'].update(futurePermission={}),
            lambda p: p['permissions'].pop('fileSystem'),
            lambda p: p['permissions']['fileSystem'].pop('entries'),
            lambda p: p['permissions']['fileSystem'].update(read=['/private']),
            lambda p: p['permissions']['fileSystem'].update(globScanMaxDepth=3),
            lambda p: p['permissions']['fileSystem'].update(entries=[]),
            lambda p: p['permissions']['fileSystem']['entries'][1].update(access='deny'),
            lambda p: p['permissions']['fileSystem']['entries'][1].update(access=[]),
            lambda p: p['permissions']['fileSystem']['entries'][0].update(
                path=dict(type='special', value=dict(kind='root'))),
            lambda p: p['permissions']['fileSystem']['entries'][0].update(
                path=dict(type='glob_pattern', pattern='/Users/**')),
            lambda p: p['permissions']['fileSystem']['entries'][0]['path'].update(path='relative'),
            lambda p: p['permissions']['fileSystem']['entries'][0]['path'].update(path='/a/../b'),
            lambda p: p['permissions']['fileSystem']['entries'][0]['path'].update(path='/a\nRead only'),
        ]
        for mutate in mutations:
            raw = deepcopy(original)
            mutate(raw['params'])
            with self.subTest(params=raw['params']):
                self.assertIsNone(decode_request('session', raw, desktop=True))
        self.assertIsNone(decode_request('another-session', original, desktop=True))

    def test_typed_entries_without_deprecated_duplicates_remain_supported(self):
        for legacy in ('absent', 'null'):
            raw = request()
            filesystem = raw['params']['permissions']['fileSystem']
            for access in ('read', 'write'):
                if legacy == 'absent':
                    filesystem.pop(access)
                else:
                    filesystem[access] = None
            filesystem['globScanMaxDepth'] = None
            with self.subTest(legacy=legacy):
                self.assertIsNotNone(decode_request('session', raw, desktop=True))

    def test_desktop_never_restores_writes_filtered_by_native_prose_mode(self):
        for path in ('/', '/private/tmp', str(Path.home()), str(Path.home() / 'Library' / 'Private')):
            raw = request()
            filesystem = raw['params']['permissions']['fileSystem']
            filesystem['entries'][1]['path']['path'] = path
            filesystem['write'] = [path]
            with self.subTest(path=path):
                self.assertIsNone(decode_request('session', raw, desktop=True))
                self.assertIsNotNone(decode_request('session', raw))

    def test_read_and_write_paths_stay_distinct_and_grants_are_captured(self):
        raw = request()
        raw['params']['permissions']['fileSystem']['entries'].append(
            dict(access='read', path=dict(type='path', path='/private/read-only')))
        raw['params']['permissions']['fileSystem']['read'].append('/private/read-only')
        public, encode = decode_request('session', raw, desktop=True)
        self.assertEqual(public['approval']['displayText'], 'View contents:\n/private/read-only\n\n'
                         'View and edit contents:\n' + str(Path.home() / 'Desktop'))
        expected = deepcopy(raw['params']['permissions'])
        raw['params']['permissions'].clear()
        response = encode(dict(action='choose', optionID='turn'))[1]['response']
        self.assertEqual(response['permissions'], expected)
        response['permissions'].clear()
        self.assertEqual(encode(dict(action='choose', optionID='turn'))[1]['response']['permissions'], expected)
        self.assertIsNone(encode(dict(action='release')))
        self.assertIsNone(encode(dict(action='choose', optionID='always')))
        self.assertIsNone(encode(dict(action='choose', optionID='session')))
