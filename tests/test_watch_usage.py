from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

@unittest.skipUnless(sys.platform == "darwin", "Requires Swift")
class WatchUsageTests(unittest.TestCase):
    def test_selection_and_cache_ordering(self):
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            binary=Path(temporary)/"usage-tests"
            subprocess.run(["xcrun","swiftc","-warnings-as-errors","-parse-as-library",
                str(root/"ios/Shared/WatchAllowanceSnapshot.swift"),str(root/"tests/WatchUsageTransitions.swift"),
                "-o",str(binary)],check=True,capture_output=True,text=True)
            result=subprocess.run([str(binary)],check=True,capture_output=True,text=True)
            self.assertIn("watch usage transitions passed",result.stdout)
