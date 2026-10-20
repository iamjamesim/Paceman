"""Legacy hooks must never intercept native questions or permissions."""
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from macos import interaction_hook as hook


class InteractionHookTests(unittest.TestCase):
    def test_legacy_invocations_never_read_payload_connect_or_return_a_decision(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                output = io.StringIO()
                with patch("socket.socket", side_effect=AssertionError("Must not connect")):
                    hook.run(provider, object(), output)
                self.assertEqual(output.getvalue(), "")

    def test_cli_preserves_questions_approvals_and_all_native_choices(self):
        script = Path(__file__).resolve().parents[1] / "macos/interaction_hook.py"
        for provider in ("codex", "claude"):
            for event, tool in (("PreToolUse", "request_user_input"),
                                ("PreToolUse", "request_user_input_async"),
                                ("PreToolUse", "AskUserQuestion"),
                                ("PermissionRequest", "mcp__pages__edit")):
                payload = {"hook_event_name": event, "tool_name": tool,
                           "tool_input": {"questions": [{"question": "Which?",
                               "options": [str(i) for i in range(25)]}],
                               "large_input": "x" * 70000},
                           "permission_suggestions": [{"type": "addRules"}]}
                with self.subTest(provider=provider, event=event, tool=tool):
                    result = subprocess.run([sys.executable, str(script), "--provider", provider],
                        input=json.dumps(payload), capture_output=True, text=True, timeout=2)
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr, "")
