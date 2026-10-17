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
        for event in ("PostToolUse", "Stop", "SessionStart"):
            value = approval(); value["hook_event_name"] = event
            cases.append(("claude", value))
        value = question(); value["hook_event_name"] = "PermissionRequest"
        cases.append(("claude", value))
        for provider, value in cases:
            output, exchange = self.run_hook(provider, value, {"action": "allowOnce"})
            self.assertEqual(output, "")
            exchange.assert_not_called()

    def test_codex_blocking_and_async_answers_skip_duplicate_native_question(self):
        for tool, questions in (
            ("request_user_input", [{"id": "approach", "header": "Approach", "question": "Which café?",
                "options": [{"label": "北", "description": "North"}, {"label": "南", "description": "South"}]}]),
            ("request_user_input_async", [{"title": "Which café?", "options": ["北", "南"]}]),
            ("request_user_input_async", [{"title": "Anything else?"}])):
            value = {"session_id": "native-session", "hook_event_name": "PreToolUse",
                     "tool_name": tool, "tool_input": {"questions": questions}}
            for answer in ({"selected": [], "text": "près du parc"},
                           {"selected": [1], "text": ""}) if questions[0].get("options") else (
                               {"selected": [], "text": "près du parc"},):
                with self.subTest(tool=tool, answer=answer), patch.object(hook, "notify_answered") as notify:
                    output, exchange = self.run_hook("codex", value,
                        {"action": "answer", "answers": {"q0": answer}})
                    result = json.loads(output)["hookSpecificOutput"]
                    self.assertEqual(result["permissionDecision"], "deny")
                    self.assertNotIn("updatedInput", result)
                    answers = json.loads(result["permissionDecisionReason"].split("\n", 1)[1])
                    key = "approach" if tool == "request_user_input" else "q0"
                    self.assertEqual(answers[key]["answer"], answer["text"] or "南")
                    self.assertEqual(exchange.call_args.args[0]["provider"], "codex")
                    notify.assert_called_once_with(value)

    def test_codex_multiple_questions_preserve_native_ids_even_with_identical_prompts(self):
        value = {"session_id": "native-session", "hook_event_name": "PreToolUse",
                 "tool_name": "request_user_input", "tool_input": {"questions": [
                     {"id": "first", "question": "Which?", "options": None},
                     {"id": "second", "question": "Which?", "options": None}]}}
        with patch.object(hook, "notify_answered"):
            output, _ = self.run_hook("codex", value, {"action": "answer", "answers": {
                "q0": {"text": "A"}, "q1": {"text": "B"}}})
        answers = json.loads(json.loads(output)["hookSpecificOutput"]["permissionDecisionReason"].split("\n", 1)[1])
        self.assertEqual(answers, {"first": {"question": "Which?", "answer": "A"},
                                   "second": {"question": "Which?", "answer": "B"}})

    def test_question_completion_notification_contains_only_invocation_metadata(self):
        original = {"session_id": "native-session", "turn_id": "turn-1", "tool_use_id": "call-1",
                    "tool_input": {"questions": [{"title": "Private question"}]}}
        with patch("macos.codex_hook.deliver") as deliver:
            hook.notify_answered(original)
        message = deliver.call_args.args[0]
        self.assertEqual(message, {"command": "agent-event", "session": "native-session",
            "turn": "turn-1", "event": "question-answered", "toolID": "call-1",
            "hook": "PacemanQuestionAnswered"})
        self.assertNotIn("Private question", json.dumps(message))
        with patch("macos.codex_hook.deliver") as deliver:
            hook.notify_answered({"session_id": "native-session"})
            deliver.assert_not_called()

    def test_codex_secret_malformed_and_duplicate_questions_stay_native(self):
        base = {"session_id": "native-session", "hook_event_name": "PreToolUse",
                "tool_name": "request_user_input", "tool_input": {"questions": [
                    {"id": "choice", "question": "Which?", "options": None}]}}
        for change in ({"isSecret": True}, {"options": False}, {"id": ""}, {"question": ""}):
            value = copy.deepcopy(base); value["tool_input"]["questions"][0].update(change)
            output, exchange = self.run_hook("codex", value, {"action": "answer"})
            self.assertEqual(output, "")
            exchange.assert_not_called()
        value = copy.deepcopy(base)
        value["tool_input"]["questions"].append({"id": "choice", "question": "Another?"})
        self.assertIsNone(hook.normalize("codex", value))
        for reply in (None, {"action": "release"}, {"action": "deny"},
                      {"action": "answer", "answers": {"wrong": {"text": "yes"}}}):
            output, _ = self.run_hook("codex", base, reply)
            self.assertEqual(output, "")

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
            connection.settimeout.assert_called_once_with(602)
            envelope = json.loads(connection.sendall.call_args.args[0])
            self.assertEqual(envelope, {"request": request, "timeoutSeconds": 600})

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
