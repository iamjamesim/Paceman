"""Exercise the real Swift panel model with controlled, out-of-order command completions."""
from pathlib import Path
import subprocess
import platform
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Requires SwiftUI and the Mac SDK")
class MacPanelTransitionTests(unittest.TestCase):
    def test_async_state_transitions(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / "macos/PacemanMac.swift").read_text()
        # Keep the production model and views in the same compilation unit so private
        # types stay private in the app; replace only its executable entry point.
        source, app = source.split("\n@main\nstruct PacemanMacApp: App", 1)
        self.assertTrue(app)
        # Exercise the welcome screen even though the test binary is outside Applications.
        source = source.replace("static var isInApplications: Bool { appLocations.contains(Bundle.main.bundlePath) }",
                                "static var isInApplications: Bool { true }")
        # Keep notification-repair fixtures away from the user's installed state.
        source = source.replace(
            'static let notificationMarker = NSHomeDirectory() + "/Library/Application Support/Paceman/notification-setup-incomplete"',
            'static let notificationMarker = FileManager.default.temporaryDirectory.appendingPathComponent("paceman-panel-notification-" + UUID().uuidString).path')
        source += (root / "tests/MacPanelTransitions.swift").read_text()
        with tempfile.TemporaryDirectory(prefix="paceman-panel-tests-") as directory:
            directory = Path(directory)
            swift = directory / "Transitions.swift"
            swift.write_text(source)
            binary = directory / "transitions"
            build = subprocess.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-warnings-as-errors",
                            "-target", platform.machine() + "-apple-macosx15.0",
                            str(swift), str(root / "ios/Shared/PacemanMark.swift"),
                            "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("transition scenarios passed", result.stdout)
