"""Synthetic handoffs only: no installed app, launch agents, or user credentials."""
from contextlib import ExitStack, closing, nullcontext
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from macos import updates
from service.compatibility import service_build
from service.hub import Store
from service.interactions import BrokerError, InteractionBroker
from service.update_control import UpdateControl, admission, request, _Handler
from tests.test_interactions import approval, response


class AdmissionTests(unittest.TestCase):
    token = '00000000-0000-4000-8000-000000000001'

    def journal(self, root):
        (root / 'update-pending.json').write_text(json.dumps(
            {'schema': 1, 'token': self.token, 'phase': 'admitting'}))

    def test_active_work_and_pending_or_uncertain_responses_defer_update(self):
        with tempfile.TemporaryDirectory(prefix='pmu-') as directory, ExitStack() as stack:
            root = Path(directory)
            self.journal(root)
            store = Store(root / 'hub.sqlite3')
            broker = InteractionBroker()
            stack.callback(broker.close)
            path = root / 'update.sock'
            adapter = SimpleNamespace(lock=threading.RLock(), recovering_sessions={})
            stack.enter_context(UpdateControl(path, store, adapter, broker))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            store.emit('working')
            with self.assertRaises(ValueError):
                with admission(path, self.token):
                    self.fail('Active work admitted')
            store.emit('idle')
            pending = broker.publish_live(approval())
            with self.assertRaises(ValueError):
                with admission(path, self.token):
                    self.fail('Pending request admitted')
            broker.submit(response(broker, pending))
            with self.assertRaises(ValueError):
                with admission(path, self.token):
                    self.fail('Uncertain response admitted')
            broker.withdraw(pending)
            # Recovered owner state is still unknown until reconciled.
            adapter.recovering_sessions = {'fixture': 'unknown'}
            with self.assertRaises(ValueError):
                with admission(path, self.token):
                    self.fail('Unknown owner state admitted')
            adapter.recovering_sessions.clear()
            with admission(path, self.token):
                with self.assertRaises(BrokerError):
                    broker.publish_live(approval())
                with self.assertRaises(BrokerError):
                    broker.submit(response(broker, pending))
                request(path, 'resume', token=self.token)
            self.assertIsNotNone(broker.publish_live(approval()))
        self.assertFalse(path.exists())

    def test_disconnected_preparing_client_reopens_admission_without_resume(self):
        with tempfile.TemporaryDirectory(prefix='pmu-') as directory, ExitStack() as stack:
            root = Path(directory)
            self.journal(root)
            store = Store(root / 'hub.sqlite3')
            broker = InteractionBroker()
            stack.callback(broker.close)
            path = root / 'update.sock'
            stack.enter_context(UpdateControl(path, store, SimpleNamespace(lock=threading.RLock()), broker))
            released = threading.Event()
            original = broker.resume_after_update
            def resume():
                original()
                released.set()
            with patch.object(broker, 'resume_after_update', side_effect=resume):
                with admission(path, self.token):
                    with self.assertRaises(BrokerError):
                        broker.publish_live(approval())
                self.assertTrue(released.wait(1), 'EOF did not reopen response admission')
            self.assertIsNotNone(broker.publish_live(approval()))

    def test_does_not_remove_unrelated_file_or_symlink(self):
        with tempfile.TemporaryDirectory(prefix='pmu-') as directory:
            path = Path(directory) / 'update.sock'
            path.write_text('keep')
            with self.assertRaises(ValueError):
                UpdateControl(path, None, None, None).__enter__()
            self.assertEqual(path.read_text(), 'keep')

    def test_source_shutdown_does_not_wait_for_the_preparing_client(self):
        with tempfile.TemporaryDirectory(prefix='pmu-') as directory:
            root = Path(directory)
            self.journal(root)
            store = Store(root / 'hub.sqlite3')
            broker = InteractionBroker()
            control = UpdateControl(root / 'update.sock', store,
                                    SimpleNamespace(lock=threading.RLock()), broker).__enter__()
            try:
                with admission(control.path, self.token), ThreadPoolExecutor(max_workers=1) as pool:
                    pool.submit(control.__exit__, None, None, None).result(timeout=2)
                    self.assertIsNotNone(broker.publish_live(approval()))
            finally:
                if not control.closed:
                    control.__exit__(None, None, None)
                broker.close()


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pmu-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'Applications/Paceman.app'
        (self.app / 'Contents').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '31'}))
        self.plist = self.root / 'source.plist'
        self.plist.write_bytes(plistlib.dumps({'Label': updates.LABEL, 'ProgramArguments': [
            str(self.app / 'Contents/MacOS/PacemanBackground'), '/fixture/python', str(self.root)]}))
        (self.root / 'lib/service').mkdir(parents=True)
        (self.root / 'lib/service/example.py').write_text('# fixture')
        (self.root / 'lib/build-info.json').write_text(json.dumps({'sourceRevision': 'a' * 40}))
        (self.root / 'installed-build').write_text('31')
        (self.root / 'installed-app').write_text(str(self.app))
        (self.root / 'agents.json').write_text('{"providers":[]}')
        self.store = Store(self.root / 'data/hub.sqlite3')
        self.source_id = self.store.metadata('source_id')
        with self.store.connect() as db:
            db.execute("INSERT INTO clients VALUES ('fixture-client', 'fixture-hash', 1, 0, NULL)")
            db.execute("INSERT INTO completed_sessions VALUES ('codex', 'fixture-session', 1, '{}')")
        self.loaded = True
        self.calls = []
        self.request = self.enterContext(patch('macos.updates.request'))
        self.admission = self.enterContext(patch('macos.updates.admission', return_value=nullcontext()))
        self.enterContext(patch('macos.updates._launch', side_effect=self.launch))

    def launch(self, *args):
        self.calls.append(args)
        result = 0
        if args[0] == 'print':
            result = 0 if args[1].endswith('/' + updates.LABEL) and self.loaded else 1
        elif args[0] == 'bootout':
            self.loaded = False
        elif args[0] == 'bootstrap':
            self.loaded = True
            self.status()
        return subprocess.CompletedProcess(args, result)

    def status(self, **changes):
        (self.root / 'status.json').write_text(json.dumps(dict(
            running=True, startedAt=time.time(), updatedAt=time.time(),
            serviceBuild=service_build(self.root / 'lib'), sourceID=self.source_id, **changes)))

    def test_prepare_checkpoints_identity_pairings_and_preserves_choices_then_recovers(self):
        agents = (self.root / 'agents.json').read_bytes()
        updates.prepare(self.root, self.plist, self.app)
        self.assertFalse(self.loaded)
        with closing(sqlite3.connect(self.root / 'update-backup.sqlite3')) as db:
            self.assertEqual(db.execute("SELECT value FROM metadata WHERE key='source_id'").fetchone()[0], self.source_id)
            self.assertEqual(db.execute('SELECT id,hash FROM clients').fetchall(), [('fixture-client', 'fixture-hash')])
            self.assertEqual(db.execute('SELECT provider,id FROM completed_sessions').fetchall(), [('codex', 'fixture-session')])
        self.assertEqual((self.root / 'update-backup.sqlite3').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'agents.json').read_bytes(), agents)
        with self.assertRaises(SystemExit) as stopped:
            updates.check_service_start(self.root)
        self.assertEqual(stopped.exception.code, 0)
        updates.recover(self.root, self.plist, self.app)
        self.assertTrue(self.loaded)
        self.assertFalse((self.root / 'update-pending.json').exists())
        self.assertFalse((self.root / 'sharing-paused').exists())

    def test_paused_install_never_starts_workers(self):
        self.loaded = False
        (self.root / 'sharing-paused').write_text('paused')
        updates.prepare(self.root, self.plist, self.app)
        updates.recover(self.root, self.plist, self.app)
        self.assertFalse(self.loaded)
        self.request.assert_not_called()
        self.admission.assert_not_called()
        self.assertTrue((self.root / 'sharing-paused').exists())

    def test_new_app_cannot_restart_old_components_or_silently_restore_database(self):
        updates.prepare(self.root, self.plist, self.app)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '32'}))
        with self.assertRaisesRegex(ValueError, 'updated Paceman'):
            updates.recover(self.root, self.plist, self.app)
        self.assertFalse(self.loaded)
        self.assertTrue((self.root / 'update-backup.sqlite3').exists())

    def test_interruption_after_successful_component_commit_only_finalizes_current_build(self):
        updates.prepare(self.root, self.plist, self.app)
        updates.before_start(self.root)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '32'}))
        (self.root / 'installed-build').write_text('32')
        embedded = self.app / 'Contents/Resources/lib'
        embedded.mkdir(parents=True)
        provenance = json.dumps({'sourceRevision': 'b' * 40})
        (self.root / 'lib/build-info.json').write_text(provenance)
        (embedded / 'build-info.json').write_text(provenance)
        self.loaded = True
        self.status()
        calls = len(self.calls)
        updates.recover(self.root, self.plist, self.app)
        self.assertEqual(len(self.calls), calls)
        self.assertTrue(self.loaded)
        self.assertFalse((self.root / 'update-pending.json').exists())
        self.assertEqual(self.store.metadata('source_id'), self.source_id)

    def test_component_mismatch_is_rejected_before_database_open(self):
        embedded = self.app / 'Contents/Resources/lib'
        embedded.mkdir(parents=True)
        (embedded / 'build-info.json').write_text(json.dumps({'sourceRevision': 'b' * 40}))
        with self.assertRaisesRegex(SystemExit, 'components'):
            updates.check_service_start(self.root)

    def test_failed_checkpoint_resumes_unchanged_build_and_propagates_error(self):
        with patch('macos.updates._checkpoint', side_effect=OSError('disk full')):
            with self.assertRaisesRegex(OSError, 'disk full'):
                updates.prepare(self.root, self.plist, self.app)
        self.assertTrue(self.loaded)
        self.assertFalse((self.root / 'update-pending.json').exists())

    def test_failed_journal_write_never_requests_admission_or_stops_workers(self):
        with patch('macos.updates._write', side_effect=OSError('disk full')):
            with self.assertRaisesRegex(OSError, 'disk full'):
                updates.prepare(self.root, self.plist, self.app)
        self.assertTrue(self.loaded)
        self.request.assert_not_called()
        self.admission.assert_not_called()
        self.assertFalse(any(call[0] == 'bootout' for call in self.calls))

    def live_control(self):
        # The only live boundary is a temporary socket and synthetic database.
        broker = InteractionBroker()
        self.addCleanup(broker.close)
        adapter = SimpleNamespace(lock=threading.RLock())
        control = self.enterContext(UpdateControl(self.root / 'update.sock', self.store, adapter, broker))
        self.status()
        return control, broker, adapter

    def drop_prepare_reply(self, original, *, silent=False):
        root = self.root
        def reply(handler, value):
            active = handler.server.control.active
            if active is not None and active[0] is handler.connection:
                handler.drop_reply = True
                self.assertEqual(json.loads((root / 'update-pending.json').read_text())['phase'], 'admitting')
            if getattr(handler, 'drop_reply', False):
                if silent:
                    return  # Simulate a sent acknowledgement that never arrives.
                raise BrokenPipeError('fixture lost prepare acknowledgement')
            return original(handler, value)
        return reply

    def test_lost_prepare_acknowledgement_recovers_without_stopping_workers(self):
        _control, broker, _adapter = self.live_control()
        for silent in (False, True):
            with self.subTest(silent_drop=silent), \
                 patch('macos.updates.admission', side_effect=lambda path, token: admission(path, token, timeout=.05)), \
                 patch('macos.updates.request', side_effect=request), \
                 patch.object(_Handler, '_reply', self.drop_prepare_reply(_Handler._reply, silent=silent)):
                with self.assertRaises((ValueError, TimeoutError)):
                    updates.prepare(self.root, self.plist, self.app)
            self.assertFalse((self.root / 'update-pending.json').exists())
            self.assertFalse(any(call[0] == 'bootout' for call in self.calls))
            self.assertTrue(self.loaded)
            pending = broker.publish_live(approval())
            broker.withdraw(pending)

    def test_delayed_prepare_cannot_close_admission_after_timeout_and_recovery(self):
        control, broker, adapter = self.live_control()
        entered, finished = threading.Event(), threading.Event()
        original = control.prepare
        def delayed(connection, token):
            entered.set()
            try:
                return original(connection, token)
            finally:
                finished.set()
        with patch.object(control, 'prepare', side_effect=delayed), \
             patch.object(broker, 'prepare_update', wraps=broker.prepare_update) as gate, \
             patch('macos.updates.admission', side_effect=lambda path, token: admission(path, token, timeout=.05)), \
             patch('macos.updates.request', side_effect=request), ThreadPoolExecutor(max_workers=1) as pool:
            with adapter.lock:
                pending = pool.submit(updates.prepare, self.root, self.plist, self.app)
                self.assertTrue(entered.wait(1))
                with self.assertRaises(TimeoutError):
                    pending.result(timeout=2)
                self.assertFalse((self.root / 'update-pending.json').exists())
            self.assertTrue(finished.wait(1))
            gate.assert_not_called()
        self.assertFalse(any(call[0] == 'bootout' for call in self.calls))
        self.assertIsNotNone(broker.publish_live(approval()))

    def test_lost_acknowledgement_keeps_journal_if_recovery_fails_then_allows_retry(self):
        _control, broker, _adapter = self.live_control()
        def fail_resume(path, command, **kwargs):
            if command == 'resume':
                raise TimeoutError('fixture recovery acknowledgement lost')
            return request(path, command, **kwargs)
        with patch('macos.updates.admission', side_effect=admission), \
             patch('macos.updates.request', side_effect=fail_resume), \
             patch.object(_Handler, '_reply', self.drop_prepare_reply(_Handler._reply)):
            with self.assertRaisesRegex(TimeoutError, 'recovery acknowledgement lost'):
                updates.prepare(self.root, self.plist, self.app)
        self.assertTrue((self.root / 'update-pending.json').exists())
        # Failed delivery released the admission independently of client recovery.
        pending = broker.publish_live(approval())
        broker.withdraw(pending)
        with patch('macos.updates.request', side_effect=request):
            updates.recover(self.root, self.plist, self.app)
        self.assertFalse((self.root / 'update-pending.json').exists())
        self.assertTrue(self.loaded)

    def test_unrelated_job_is_not_stopped(self):
        self.plist.write_bytes(plistlib.dumps({'Label': 'somebody.else'}))
        with self.assertRaisesRegex(ValueError, 'background item'):
            updates.prepare(self.root, self.plist, self.app)
        self.assertEqual(self.calls, [])

    def test_push_worker_must_release_its_lock_before_checkpoint(self):
        with (self.root / 'data/push.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.assertRaisesRegex(ValueError, 'still stopping'):
                updates._stopped(self.root, timeout=0)

    def test_readiness_requires_expected_build_identity_and_live_control_socket(self):
        self.status()
        expected = service_build(self.root / 'lib')
        updates.wait_ready(self.root, expected, source_id=self.source_id, timeout=0)
        for invalid in ({'sourceID': 'other'}, {'serviceBuild': {'sourceRevision': 'b' * 40}},
                        {'running': False}, {'updatedAt': 0}):
            value = json.loads((self.root / 'status.json').read_text())
            value.update(invalid)
            (self.root / 'status.json').write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'expected background build'):
                updates.wait_ready(self.root, expected, source_id=self.source_id, timeout=0)
            self.status()
        with patch('macos.updates.request', side_effect=OSError('socket missing')):
            with self.assertRaisesRegex(ValueError, 'expected background build'):
                updates.wait_ready(self.root, expected, timeout=0)
