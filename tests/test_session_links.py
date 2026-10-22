import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from service.hub import Store
from service.macos import MacSource
from service.omarchy import OmarchySource
from service.processes import AgentProcesses, ProcessIdentity
from service.push import live_notification, notification_copy


THREADS = ('01a15fac-3987-72a0-aebc-48995026e622', '01a15fac-3987-72a0-aebc-48995026e623')


class SessionLinkTests(unittest.TestCase):
    def source(self, kind, root, store):
        args = dict(socket_path=root / 'hook.sock', title_reader=lambda _: {})
        if kind == 'mac':
            return MacSource(store, allowance_reader=lambda: None, **args)
        processes = Mock(spec=AgentProcesses)
        processes.identify.side_effect = lambda pid: ProcessIdentity(pid, '1', 'boot')
        processes.is_alive.return_value = True
        return OmarchySource(store, state_dir=root, processes=processes,
                             turn_metadata_reader=lambda _: {}, **args)

    def receive(self, source, session, event='working', pid=100):
        command = dict(command='agent-event', session=session, turn='turn', event=event,
                       hook='UserPromptSubmit' if event == 'working' else 'Stop')
        if isinstance(source, OmarchySource):
            return source.receive(dict(command, source='codex', adapter='paceman'), peer_pid=pid)
        return source.receive(command)

    def test_sources_publish_distinct_thread_destinations_and_preserve_result_links_on_restart(self):
        for kind in ('mac', 'omarchy'):
            with self.subTest(source=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                root.chmod(0o700)
                path = root / 'hub.sqlite3'
                store = Store(path)
                with self.source(kind, root, store) as source:
                    for index, thread in enumerate(THREADS):
                        self.receive(source, thread, pid=100 + index)
                    snapshot = store.snapshot()
                    rows = snapshot['sessions']
                    self.assertEqual({row['threadID'] for row in rows}, set(THREADS))
                    for row in rows:
                        self.assertEqual(row['id'], hashlib.sha256(('codex:' + row['threadID']).encode()).hexdigest())
                    for thread in THREADS:
                        self.assertNotIn(thread, json.dumps(live_notification(snapshot, snapshot['observedAt'])))
                        self.assertNotIn(thread, json.dumps(notification_copy(
                            dict(state=snapshot['state'], payload=json.dumps(snapshot)))))
                    for index, thread in enumerate(THREADS):
                        self.receive(source, thread, 'completed', pid=100 + index)
                        self.receive(source, thread, 'ended', pid=100 + index)
                with patch('service.macos.time.time', return_value=time.time() + 3600):
                    store = Store(path)
                    with self.source(kind, root, store):
                        snapshot = store.snapshot()
                        self.assertEqual(snapshot['sessions'], [])
                        self.assertEqual({row['threadID'] for row in snapshot['completedSessions']}, set(THREADS))

    def test_sources_omit_non_uuid_destinations(self):
        for kind in ('mac', 'omarchy'):
            with self.subTest(source=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                root.chmod(0o700)
                store = Store(root / 'hub.sqlite3')
                with self.source(kind, root, store) as source:
                    self.receive(source, 'opaque-local-id')
                    self.assertNotIn('threadID', store.snapshot()['sessions'][0])
