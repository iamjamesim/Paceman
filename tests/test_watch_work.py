from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Requires Swift")
class WatchWorkTests(unittest.TestCase):
    def test_activation_lifecycle(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "watch-work-tests"
            result = subprocess.run([
                "xcrun", "swiftc", "-warnings-as-errors", "-parse-as-library",
                str(root / "ios/Shared/LiveActivityRoute.swift"),
                str(root / "ios/Shared/ApprovalContent.swift"),
                str(root / "ios/Shared/WatchWork.swift"),
                str(root / "tests/WatchWorkTransitions.swift"), "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary), str(root / 'tests/fixtures/session-temporal.json')],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("watch work transitions passed", result.stdout)
            self.assertIn("watch review transitions passed", result.stdout)
            print(result.stdout.strip())
