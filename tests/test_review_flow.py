from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


def section(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


@unittest.skipUnless(sys.platform == "darwin", "Requires Swift")
class ReviewFlowTests(unittest.TestCase):
    def test_review_transitions_without_installing_an_app(self):
        root = Path(__file__).resolve().parents[1]
        phone = root / "ios/AgentCompanion"
        models = (phone / "Models.swift").read_text()
        interactions = (phone / "Interactions.swift").read_text()
        # Compile the actual phone policy, request lock and current-request guard.
        # The harness supplies only platform-bound containers; it does not copy
        # the transition logic or exercise an installed app/source.
        source = "import Foundation\n" + "\n".join([
            section(models, "enum ActivityState:", "struct Snapshot:"),
            section(models, "struct PairedSource:", "struct ClientDevice:"),
            section((phone / "PresentationModel.swift").read_text(), "struct AgentSession:", "/// A missing session list"),
            section(interactions, "struct PendingInput:", "/// Request content lives"),
            section((phone / "CompanionHome.swift").read_text(), "struct WorkIdentity:", "extension LiveActivityRoute"),
            section((phone / "TaskCard.swift").read_text(), "struct TaskReviewQueue:", "/// One current-task card"),
        ])
        guard = section(interactions, "    func isCurrent(_ item:", "    @discardableResult func refresh(")
        harness = (root / "tests/ReviewFlowTransitions.swift").read_text().replace("// CURRENT_REQUEST_GUARD", guard)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "PhonePolicy.swift").write_text(source)
            (directory / "Transitions.swift").write_text(harness)
            binary = directory / "review-flow-tests"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-warnings-as-errors", "-parse-as-library",
                str(root / "ios/Shared/LiveActivityRoute.swift"),
                str(root / "ios/Shared/ApprovalContent.swift"),
                str(root / "ios/Shared/WatchWork.swift"),
                str(directory / "PhonePolicy.swift"), str(directory / "Transitions.swift"),
                "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("review flow transitions passed", result.stdout)
            print(result.stdout.strip())
