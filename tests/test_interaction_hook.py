import copy
import hashlib
import io
import json
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from macos import interaction_hook as hook


def approval():
    return {"session_id": "native-session", "turn_id": "turn-1", "cwd": "/tmp/work",
            "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": {"command": "printf '你好'", "description": "Show the greeting"}}


def question():
    return {"session_id": "native-session", "hook_event_name": "PreToolUse",
            "tool_name": "AskUserQuestion", "tool_use_id": "call-1",
            "tool_input": {"questions": [
                {"question": "Which café? ☕", "header": "Place", "multiSelect": False,
                 "options": [{"label": "北", "description": "North"},
                             {"label": "南", "description": "South"}]},
                {"question": "Which days?", "header": "Days", "multiSelect": True,
                 "options": [{"label": "Monday", "description": ""},
                             {"label": "Friday", "description": ""}]}],
                "metadata": {"source": "original-only"}}}


class InteractionHookTests(unittest.TestCase):
    def run_hook(self, provider, data, reply=None, error=None):
        raw = data if isinstance(data, bytes) else json.dumps(data).encode()
        output = io.StringIO()
        with patch.object(hook, "exchange", return_value=reply, side_effect=error) as exchange:
            hook.run(provider, io.BytesIO(raw), output)
        return output.getvalue(), exchange

    def test_provider_scoped_session_matches_monitoring(self):
        for provider in ("claude", "codex"):
            request = hook.normalize(provider, approval())
            self.assertEqual(request["sessionID"], hashlib.sha256(
                f"{provider}:native-session".encode()).hexdigest())
            self.assertEqual(request["provider"], provider)
            self.assertNotIn("turn_id", request)
            self.assertIn("Tool: Bash\nWorking directory: /tmp/work", request["detail"])
            self.assertEqual(json.loads(request["detail"].split("\n\n", 1)[1]),
                             approval()["tool_input"])

    def test_native_approval_outputs_no_persistent_permission(self):
        for provider in ("claude", "codex"):
            for action, behavior in (("allowOnce", "allow"), ("deny", "deny")):
                with self.subTest(provider=provider, action=action):
                    output, exchange = self.run_hook(provider, approval(), {"action": action})
                    decision = {"behavior": behavior}
                    if behavior == "deny":
                        decision["message"] = "Declined from Paceman."
                    self.assertEqual(json.loads(output), {"hookSpecificOutput": {
                        "hookEventName": "PermissionRequest", "decision": decision}})
                    exchange.assert_called_once()

    def test_questions_preserve_originals_and_map_exact_unicode_text(self):
        original = question()
        before = copy.deepcopy(original)
        output, exchange = self.run_hook("claude", original, {"action": "answer", "answers": {
            "q0": {"selected": [0], "text": "With a terrace"},
            "q1": {"selected": [0, 1], "text": ""}}})
        result = json.loads(output)["hookSpecificOutput"]
        self.assertEqual(result["hookEventName"], "PreToolUse")
        self.assertEqual(result["permissionDecision"], "allow")
        self.assertEqual(result["updatedInput"]["questions"], before["tool_input"]["questions"])
        self.assertEqual(result["updatedInput"]["metadata"], before["tool_input"]["metadata"])
        self.assertEqual(result["updatedInput"]["answers"], {
            "Which café? ☕": "北\nWith a terrace", "Which days?": "Monday, Friday"})
        self.assertEqual(original, before)
        request = exchange.call_args.args[0]
        self.assertEqual([q["id"] for q in request["questions"]], ["q0", "q1"])
        self.assertNotIn("metadata", json.dumps(request))

    def test_free_text_answer(self):
        original = question()
        original["tool_input"]["questions"] = original["tool_input"]["questions"][:1]
        output, _ = self.run_hook("claude", original, {"action": "answer", "answers": {
            "q0": {"selected": [], "text": "Elsewhere — près du parc"}}})
        self.assertEqual(json.loads(output)["hookSpecificOutput"]["updatedInput"]["answers"],
                         {"Which café? ☕": "Elsewhere — près du parc"})

    def test_unsupported_events_never_contact_broker(self):
        cases = [("codex", question()), ("unknown", approval())]
        for tool in ("request_user_input", "request_user_input_async"):
            value = question(); value["tool_name"] = tool
            cases.append(("codex", value))
        for event in ("PostToolUse", "Stop", "SessionStart"):
            value = approval(); value["hook_event_name"] = event
            cases.append(("claude", value))
        value = question(); value["hook_event_name"] = "PermissionRequest"
        cases.append(("claude", value))
        for provider, value in cases:
            output, exchange = self.run_hook(provider, value, {"action": "allowOnce"})
            self.assertEqual(output, "")
            exchange.assert_not_called()

    def test_unavailable_release_and_malformed_reply_fall_back_silently(self):
        for reply in (None, [], {}, {"action": "release"}, {"action": "allow"},
                      {"action": "acceptForSession"}, {"action": "answer"}):
            output, _ = self.run_hook("codex", approval(), reply)
            self.assertEqual(output, "")
        for error in (OSError("unavailable"), socket.timeout("deadline"),
                      ValueError("invalid JSON"), ConnectionResetError()):
            output, _ = self.run_hook("claude", approval(), error=error)
            self.assertEqual(output, "")

    def test_invalid_input_and_overflow_have_no_decision(self):
        cases = [b"{", b"[1]", b"null", b"x" * (hook.MAX_BYTES + 1)]
        for change in ({"session_id": ""}, {"tool_input": []}, {"cwd": "relative"},
                       {"tool_name": None}, {"tool_input": {"command": "x" * 17000}}):
            value = approval(); value.update(change); cases.append(value)
        for value in cases:
            output, exchange = self.run_hook("codex", value, {"action": "allowOnce"})
            self.assertEqual(output, "")
            exchange.assert_not_called()

    def test_invalid_question_shapes_fall_back_before_sending(self):
        cases = []
        for change in ({"question": ""}, {"options": []}, {"multiSelect": "yes"},
                       {"options": [{"label": "same"}, {"label": "same"}]}):
            value = question(); value["tool_input"]["questions"][0].update(change)
            cases.append(value)
        value = question(); value["tool_input"]["questions"] *= 2
        cases.append(value)
        for value in cases:
            output, exchange = self.run_hook("claude", value, {"action": "allowOnce"})
            self.assertEqual(output, "")
            exchange.assert_not_called()

    def test_invalid_answers_are_rejected_independently(self):
        cases = [{}, {"q0": {"selected": [0]}},
                 {"q0": {"selected": [0]}, "q1": {"text": "yes"}, "q2": {"text": "extra"}}]
        for invalid in ({"selected": [-1]}, {"selected": [2]}, {"selected": [True]},
                        {"selected": ["0"]}, {"selected": [0, 1]},
                        {"selected": [0, 0]}, {"selected": "0"},
                        {"text": "   "}, {"text": 1}, {"selected": [0], "other": 1}):
            cases.append({"q0": invalid, "q1": {"selected": [0]}})
        for answers in cases:
            output, _ = self.run_hook("claude", question(), {"action": "answer", "answers": answers})
            self.assertEqual(output, "", answers)

    def test_socket_contract_and_bounded_reply(self):
        request = hook.normalize("codex", approval())
        for raw, expected in ((b'{"action":"release"}\n', {"action": "release"}),
                              (b'{"action":"allowOnce"}', None),
                              (b"x" * (hook.MAX_BYTES + 1), None)):
            connection = MagicMock()
            connection.__enter__.return_value = connection
            connection.makefile.return_value = io.BytesIO(raw)
            with patch.object(hook.socket, "socket", return_value=connection), \
                    patch.dict(hook.os.environ, {"PACEMAN_INTERACTION_SOCKET": "/tmp/test.sock"}):
                self.assertEqual(hook.exchange(request), expected)
            connection.connect.assert_called_once_with("/tmp/test.sock")
            connection.settimeout.assert_called_once_with(62)
            envelope = json.loads(connection.sendall.call_args.args[0])
            self.assertEqual(envelope, {"request": request, "timeoutSeconds": 60})

    def test_cli_fallback_exits_zero_without_stdout_or_stderr(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(hook.os.environ, PACEMAN_INTERACTION_SOCKET=directory + "/absent.sock")
            for raw in (b"malformed", json.dumps(approval()).encode()):
                result = subprocess.run([sys.executable, hook.__file__, "--provider", "codex"],
                                        input=raw, capture_output=True, env=environment, timeout=5)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
