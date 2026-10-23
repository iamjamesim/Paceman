import json
from pathlib import Path
import tempfile
import unittest

from service.diagnostics import DeliveryDiagnostics


class DeliveryDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.path = self.root / 'delivery.jsonl'
        self.sink = DeliveryDiagnostics(self.path, maximum_bytes=1024)

    def test_only_bounded_metadata_is_retained(self):
        self.sink.record('http_replied', operation='snapshot', httpStatus=200,
                         command='SECRET', credential='SECRET', reason='SECRET',
                         requestFingerprint='SECRET', traceID='SECRET', action='SECRET', origin='SECRET', durationMs=-1)
        entry = json.loads(self.path.read_text())
        self.assertEqual(set(entry), {'at', 'stage', 'operation', 'httpStatus'})
        self.sink.record('SECRET')
        for _ in range(100):
            self.sink.record('hook_returned', durationMs=600000, provider='codex')
        self.assertLessEqual(self.path.stat().st_size, 1024)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        for line in self.path.read_text().splitlines():
            self.assertIsInstance(json.loads(line), dict)

    def test_invalid_path_and_symlink_do_not_modify_target_or_raise(self):
        target = self.root / 'untouched'
        target.write_text('untouched')
        self.path.symlink_to(target)
        self.sink.record('hook_received')
        self.assertEqual(target.read_text(), 'untouched')
        DeliveryDiagnostics(self.root / 'missing' / 'log').record('hook_received')

    def test_existing_shared_file_is_not_written(self):
        self.path.write_text('untouched')
        self.path.chmod(0o644)
        self.sink.record('hook_received')
        self.assertEqual(self.path.read_text(), 'untouched')


if __name__ == '__main__':
    unittest.main()
