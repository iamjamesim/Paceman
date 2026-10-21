import io
import json
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from service import compatibility as compat


class CompatibilityTests(unittest.TestCase):
    def test_audited_baseline_matches_provider_inventories(self):
        fixtures = Path(__file__).parent / 'fixtures'
        desktop = json.loads((fixtures / 'codex-desktop-inventory.json').read_text())
        cli = json.loads((fixtures / 'codex-appserver-inventory.json').read_text())
        claude = json.loads((fixtures / 'claude-control-inventory.json').read_text())
        self.assertEqual(compat.AUDITED, {'codexDesktop': {'version': desktop['desktop_version'],
            'build': desktop['desktop_build'], 'stream': desktop['stream_version']},
            'codexCLI': {'version': cli['cli_version']}, 'claude': {'version': claude['version']}})

    def test_build_revision_is_recorded_and_source_fingerprint_detects_local_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'service').mkdir()
            source = root / 'service/source.py'
            source.write_text('first source')
            first = compat.service_build(root)
            self.assertEqual(first['sourceRevision'], 'unknown')
            (root / 'build-info.json').write_text(json.dumps({'sourceRevision': 'a' * 40, 'secret': 'private'}))
            second = compat.service_build(root)
            self.assertEqual(second['sourceRevision'], 'a' * 40)
            self.assertEqual(second['serviceFingerprint'], first['serviceFingerprint'])
            source.write_text('second source')
            self.assertNotEqual(compat.service_build(root)['serviceFingerprint'], first['serviceFingerprint'])
            (root / '.git').touch()
            with patch('service.compatibility.subprocess.check_output', return_value='b' * 40 + '\n'):
                self.assertEqual(compat.install_build(root)['sourceRevision'], 'b' * 40)
            self.assertNotIn('private', json.dumps(second))

    def test_version_probes_are_bounded_and_reject_unexpected_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'provider'
            for output, expected in [('codex-cli 0.163.0-alpha.10.2', '0.163.0-alpha.10.2'),
                                     ('2.1.304 (Claude Code)', '2.1.304'),
                                     ('2.1.304 private-token', 'unknown'), ('x' * 600, 'unknown')]:
                binary.write_text("#!/bin/sh\nprintf '%s\\n' '" + output + "'\n")
                binary.chmod(0o700)
                self.assertEqual(compat.binary_version(binary), expected)
            binary.write_text('#!/bin/sh\nexec /bin/sleep 5\n')
            started = time.monotonic()
            self.assertEqual(compat.binary_version(binary), 'unknown')
            self.assertLess(time.monotonic() - started, 2)
            self.assertEqual(compat.binary_version(Path(temporary) / 'missing'), 'unknown')

    def test_installed_provider_versions_do_not_claim_running_versions_or_export_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / 'Codex.app/Contents/Resources/codex'
            binary.parent.mkdir(parents=True)
            (root / 'Codex.app/Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.openai.codex', 'CFBundleShortVersionString': '26.1013.40934',
                'CFBundleVersion': '20770', 'secret': 'private'}))
            with patch('service.compatibility.codex_binary', return_value=str(binary)), \
                    patch('service.compatibility.shutil.which', return_value='/private/claude'), \
                    patch('service.compatibility.binary_version', side_effect=['0.163.0-alpha.10.2', '2.1.304']):
                versions = compat.installed_providers()
            self.assertEqual(versions['codexDesktop'], {'version': '26.1013.40934', 'build': '20770'})
            self.assertEqual(versions['claude']['version'], '2.1.304')
            self.assertNotIn('private', json.dumps(versions))
            self.assertNotIn('runtimeVersion', json.dumps(versions))

    def test_adapter_snapshot_never_waits_for_locks_or_exports_owner_ids(self):
        stop = threading.Event()
        lock = threading.Lock()
        daemon = SimpleNamespace(lock=lock, connection=object(), stop=stop, ready={'private-session'})
        self.assertEqual(compat.adapter_snapshot({'codexDaemon': daemon})['codexDaemon'],
                         {'provider': 'codex', 'connection': 'connected', 'sessions': 1})
        lock.acquire()
        try:
            started = time.monotonic()
            self.assertEqual(compat.adapter_snapshot({'codexDaemon': daemon})['codexDaemon']['connection'], 'unknown')
            self.assertLess(time.monotonic() - started, .1)
        finally:
            lock.release()
        remote = SimpleNamespace(workers={'private-session': (stop, SimpleNamespace(connected=True), None)})
        value = compat.adapter_snapshot({'claudeRemote': remote})
        self.assertEqual(value['claudeRemote']['sessions'], 1)
        self.assertNotIn('private-session', json.dumps(value))

    @patch('service.compatibility.installed_providers', return_value={})
    def test_report_uses_running_build_and_sanitizes_unknown_stale_and_private_fields(self, _providers):
        status = {'running': True, 'serviceBuild': {'sourceRevision': 'a' * 40, 'serviceFingerprint': 'b' * 16,
            'secret': 'private'}, 'auditedBaseline': compat.AUDITED,
            'nativeAdapters': {'claudeRemote': {'connection': 'connected', 'sessions': 1, 'token': 'private'},
                               'private': {'connection': 'connected'}}}
        with tempfile.TemporaryDirectory() as temporary:
            value = compat.report(Path(temporary), status)
            self.assertEqual(value['service']['observation'], 'runningService')
            self.assertEqual(value['auditedBaseline'], compat.AUDITED)
            self.assertNotIn('private', json.dumps(value))
            status['running'] = False
            stale = compat.report(Path(temporary), status)
            self.assertEqual(stale['service']['sourceRevision'], 'unknown')
            self.assertEqual(stale['observedAdapters']['claudeRemote']['connection'], 'unknown')
            self.assertNotIn('sessions', stale['observedAdapters']['claudeRemote'])
            status.update(running=True, auditedBaseline={'codexDesktop': 'private'}, nativeAdapters='private')
            self.assertNotIn('private', json.dumps(compat.report(Path(temporary), status)))

    @patch('service.compatibility.installed_providers', return_value={})
    def test_mac_and_linux_support_use_the_same_compatibility_schema(self, _providers):
        from macos.support import report
        from omarchy import control
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            status = {'running': False}
            mac = report(root, status, root / 'missing.app')
            with patch('sys.argv', ['pacemanctl', 'support']), patch.object(control, '__file__', str(root / 'lib/omarchy/control.py')), \
                    patch.object(control, 'read_status', return_value=status), patch('sys.stdout', new_callable=io.StringIO) as output:
                control.main()
            self.assertEqual(mac['compatibility'], json.loads(output.getvalue())['compatibility'])
