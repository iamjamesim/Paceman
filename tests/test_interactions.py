import concurrent.futures
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

from service.interactions import BrokerError, InteractionBroker, ResponseListener, RESPONSE_TIMEOUT_SECONDS


def approval(**changes):
    return dict(provider="claude", sessionID="a" * 64, kind="approval",
                title="Allow command?", detail="echo example", **changes)


def question(multiple=False):
    return dict(provider="claude", sessionID="a" * 64, kind="question",
                title="Choose a framework", detail="", questions=[
                    {"id": "q0", "prompt": "Which framework?", "multiple": multiple,
                     "options": [{"label": "React", "description": "First"},
                                 {"label": "Vue", "description": "Second"}]}])


def response(broker, pending, action="allowOnce", key="retry-key", **extra):
    return dict(generation=broker.generation, requestID=pending.public["requestID"],
                version=1, idempotencyKey=key, action=action, **extra)


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.
        self.broker = InteractionBroker(clock=lambda: self.now)
        self.addCleanup(self.broker.close)

    def test_first_answer_is_atomic_and_retry_does_not_deliver_twice(self):
        pending = self.broker._publish(approval(), 60)
        barrier = threading.Barrier(8)

        def submit(index):
            barrier.wait()
            try:
                return self.broker.submit(response(self.broker, pending, key=f"key-{index}"))
            except BrokerError as error:
                return error.code

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(submit, range(8)))
        self.assertEqual(sum(isinstance(r, dict) for r in results), 1)
        self.assertEqual(results.count("response_conflict"), 7)
        winner = next(i for i, r in enumerate(results) if isinstance(r, dict))
        payload = response(self.broker, pending, key=f"key-{winner}")
        self.assertEqual(self.broker.submit(payload), results[winner])
        payload["action"] = "deny"
        with self.assertRaises(BrokerError) as rejected:
            self.broker.submit(payload)
        self.assertEqual(rejected.exception.code, "response_conflict")
        self.assertEqual(pending.response, {"action": "allowOnce"})
        self.assertEqual(self.broker.pending()["requests"], [])

    def test_native_completion_is_scoped_and_prevents_late_republication(self):
        first = dict(scope='1' * 64, turn='2' * 64, session='3' * 64)
        sibling = dict(first, scope='4' * 64)
        a = self.broker._publish(approval(), 60, first)
        b = self.broker._publish(approval(), 60, sibling)
        self.broker.native_resolved('scope', first['scope'])
        self.assertEqual(a.response, {'action': 'release'})
        self.assertFalse(b.ready.is_set())
        with self.assertRaises(BrokerError):
            self.broker._publish(approval(), 60, first)
        self.broker.native_resolved('turn', first['turn'])
        self.assertEqual(b.response, {'action': 'release'})
        next_turn = dict(first, turn='5' * 64, scope='6' * 64)
        self.assertFalse(self.broker._publish(approval(), 60, next_turn).ready.is_set())

    def test_duplicate_tool_calls_are_distinct_and_snapshot_is_a_copy(self):
        a = self.broker._publish(approval(), 60)
        b = self.broker._publish(approval(), 60)
        self.assertNotEqual(a.public["requestID"], b.public["requestID"])
        snapshot = self.broker.pending()
        self.assertEqual(snapshot["requests"][0]["remainingSeconds"], 60)
        self.assertNotIn("expiresAt", snapshot["requests"][0])
        self.now += 5
        self.assertEqual(self.broker.pending()["requests"][0]["remainingSeconds"], 55)
        snapshot["requests"][0]["title"] = "tampered"
        self.assertEqual(a.public["title"], "Allow command?")
        self.broker.submit(response(self.broker, a))
        self.assertEqual(len(self.broker.pending()["requests"]), 1)
        self.assertFalse(b.ready.is_set())

    def test_deadline_and_generation_invalidation_reject_late_responses(self):
        pending = self.broker._publish(approval(), 60)
        payload = response(self.broker, pending)
        self.now += 60
        with self.assertRaises(BrokerError) as rejected:
            self.broker.submit(payload)
        self.assertEqual(rejected.exception.code, "stale_request")
        self.assertEqual(pending.response, {"action": "release"})
        new = self.broker._publish(approval(), 60)
        payload = response(self.broker, new)
        self.broker.cancel_all()
        self.assertNotEqual(payload["generation"], self.broker.generation)
        self.assertEqual(new.response, {"action": "release"})
        with self.assertRaises(BrokerError):
            self.broker.submit(payload)
        self.broker._publish(approval(), 60)  # Still usable after revocation.

    def test_question_remains_answerable_after_first_minute(self):
        pending = self.broker._publish(question(), RESPONSE_TIMEOUT_SECONDS)
        self.now += 61
        request = self.broker.pending()["requests"][0]
        self.assertEqual(request["remainingSeconds"], 539)
        self.assertEqual(request["questions"], question()["questions"])
        self.assertFalse(pending.ready.is_set())
        self.now += 538
        answers = {"q0": {"selected": [1], "text": ""}}
        receipt = self.broker.submit(response(self.broker, pending, "answer", answers=answers))
        self.assertEqual(receipt["status"], "submitted")
        self.assertEqual(pending.response, {"action": "answer", "answers": answers})

    def test_response_window_expires_at_ten_minutes_without_approving(self):
        pending = self.broker._publish(question(), RESPONSE_TIMEOUT_SECONDS)
        self.now += 599
        self.assertEqual(self.broker.pending()["requests"][0]["remainingSeconds"], 1)
        self.now += 1
        self.assertEqual(self.broker.pending()["requests"], [])
        self.assertEqual(pending.response, {"action": "release"})
        with self.assertRaises(BrokerError) as rejected:
            self.broker.submit(response(self.broker, pending, "answer",
                answers={"q0": {"selected": [0], "text": ""}}))
        self.assertEqual(rejected.exception.code, "stale_request")

    def test_question_cardinality_and_index_validation(self):
        for answer in ({"selected": [], "text": ""},
                       {"selected": [0, 1], "text": ""},
                       {"selected": [2], "text": ""},
                       {"selected": [0, 0], "text": ""},
                       {"selected": [True], "text": ""}):
            with self.subTest(answer=answer):
                pending = self.broker._publish(question(), 60)
                with self.assertRaises(BrokerError):
                    self.broker.submit(response(self.broker, pending, "answer", answers={"q0": answer}))
                self.assertFalse(pending.ready.is_set())
                self.broker._cancel(pending)
        pending = self.broker._publish(question(multiple=True), 60)
        self.broker.submit(response(self.broker, pending, "answer", answers={
            "q0": {"selected": [1, 0], "text": "A Unicode note: 日本語"}}))
        self.assertEqual(pending.response["answers"]["q0"]["selected"], [0, 1])
        self.assertIn("日本語", pending.response["answers"]["q0"]["text"])

    def test_every_question_required_and_action_must_match_kind(self):
        pending = self.broker._publish(question(), 60)
        for payload in (response(self.broker, pending),
                        response(self.broker, pending, "deny"),
                        response(self.broker, pending, "answer", answers={}),
                        response(self.broker, pending, "answer", answers={"other": {"selected": [0], "text": ""}})):
            with self.assertRaises(BrokerError):
                self.broker.submit(payload)
        result = self.broker.submit(response(self.broker, pending, "release"))
        self.assertEqual(result["status"], "submitted")
        self.assertEqual(pending.response, {"action": "release"})

    def test_codex_question_uses_the_same_scoped_answer_contract(self):
        pending = self.broker._publish(dict(question(), provider="codex"), 60)
        self.broker.submit(response(self.broker, pending, "answer", answers={
            "q0": {"selected": [0], "text": ""}}))
        self.assertEqual(pending.response, {"action": "answer", "answers": {
            "q0": {"selected": [0], "text": ""}}})

    def test_bounded_payloads_pending_and_prompt_free_receipts(self):
        for content in (dict(approval(), detail="x" * 16385),
                        dict(approval(), detail="secret\x00value"),
                        dict(approval(), provider=[]),
                        dict(approval(), sessionID="raw-session"),
                        dict(question(), questions=[])):
            with self.assertRaises(BrokerError):
                self.broker._publish(content, 60)
        for timeout in (0, 601, float("nan"), float("inf"), True):
            with self.assertRaises(BrokerError):
                self.broker._publish(approval(), timeout)
        for _ in range(32):
            self.broker._publish(approval(), 60)
        with self.assertRaises(BrokerError) as rejected:
            self.broker._publish(approval(), 60)
        self.assertEqual(rejected.exception.status, 429)
        self.broker.cancel_all()
        for _ in range(260):
            pending = self.broker._publish(question(), 60)
            self.broker.submit(response(self.broker, pending, "answer", answers={
                "q0": {"selected": [], "text": "SECRET ANSWER"}}))
        self.assertEqual(len(self.broker._receipts), 256)
        self.assertNotIn("SECRET ANSWER", repr(self.broker._receipts))
        self.assertNotIn("framework", repr(self.broker._receipts))
        self.now += 300
        self.broker.pending()
        self.assertEqual(len(self.broker._receipts), 0)

    def test_disabled_provider_and_shutdown_release_requests(self):
        enabled = {"claude"}
        broker = InteractionBroker(provider_enabled=lambda p: p in enabled)
        pending = broker._publish(approval(), 60)
        enabled.clear()
        self.assertEqual(broker.pending()["requests"], [])
        self.assertEqual(pending.response, {"action": "release"})
        with self.assertRaises(BrokerError):
            broker._publish(approval(), 60)
        enabled.add("claude")
        pending = broker._publish(approval(), 60)
        broker.close()
        self.assertEqual(pending.response, {"action": "release"})
        with self.assertRaises(BrokerError):
            broker._publish(approval(), 60)


class ListenerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.root.chmod(0o700)
        self.path = self.root / "interaction.sock"
        self.broker = InteractionBroker()
        self.listener = self.enterContext(ResponseListener(self.broker, self.path))

    def connect(self, payload=None):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(connection.close)
        connection.settimeout(2)
        connection.connect(str(self.path))
        if payload is not None:
            connection.sendall(json.dumps(payload).encode() + b"\n")
        return connection

    def until(self, predicate):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.01)
        self.fail("Timed out waiting for interaction state")

    def test_round_trip_and_no_native_consumption_claim(self):
        connection = self.connect({"request": approval()})
        request = self.until(lambda: self.broker.pending()["requests"])[0]
        self.assertGreater(request["remainingSeconds"], 590)
        result = self.broker.submit(dict(generation=self.broker.generation,
            requestID=request["requestID"], version=1, idempotencyKey="one", action="deny"))
        self.assertEqual(result["status"], "submitted")
        self.assertNotIn("consumed", result)
        self.assertEqual(json.loads(connection.recv(4096)), {"action": "deny"})
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_disconnect_and_extra_input_remove_request(self):
        for extra in (None, b"unexpected"):
            connection = self.connect({"request": approval()})
            request = self.until(lambda: self.broker.pending()["requests"])[0]
            generation = self.broker.generation
            if extra:
                connection.sendall(extra)
            else:
                connection.close()
            self.until(lambda: not self.broker.pending()["requests"])
            with self.assertRaises(BrokerError) as rejected:
                self.broker.submit(dict(generation=generation, requestID=request["requestID"],
                    version=1, idempotencyKey="late", action="allowOnce"))
            self.assertEqual(rejected.exception.code, "stale_request")

    def test_deadline_and_shutdown_release_without_decision(self):
        connection = self.connect({"request": approval(), "timeoutSeconds": .08})
        self.assertEqual(json.loads(connection.recv(4096)), {"action": "release"})
        self.assertEqual(self.broker.pending()["requests"], [])
        connection = self.connect({"request": approval()})
        self.until(lambda: self.broker.pending()["requests"])
        self.listener.close()
        self.assertEqual(json.loads(connection.recv(4096)), {"action": "release"})
        self.assertFalse(self.path.exists())

    def test_invalid_payload_never_publishes(self):
        for payload in ({"request": approval(), "timeoutSeconds": 601},
                        {"request": dict(approval(), detail="x" * 20000)},
                        {"request": approval(), "unknown": "secret"}):
            connection = self.connect(payload)
            self.assertEqual(json.loads(connection.recv(4096)), {"action": "release"})
            self.assertEqual(self.broker.pending()["requests"], [])

    def test_revocation_releases_hook_and_listener_remains_usable(self):
        connection = self.connect({"request": approval()})
        self.until(lambda: self.broker.pending()["requests"])
        self.broker.cancel_all()
        self.assertEqual(json.loads(connection.recv(4096)), {"action": "release"})
        next_connection = self.connect({"request": approval()})
        self.until(lambda: self.broker.pending()["requests"])
        next_connection.close()
        self.until(lambda: not self.broker.pending()["requests"])

    def test_owned_socket_checks_preserve_foreign_files_and_active_listener(self):
        with self.assertRaises(ValueError):
            ResponseListener(InteractionBroker(), self.path).__enter__()
        self.path = self.root / "regular"
        self.path.write_text("do not remove")
        with self.assertRaises(ValueError):
            ResponseListener(InteractionBroker(), self.path).__enter__()
        self.assertEqual(self.path.read_text(), "do not remove")
        link = self.root / "link"
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            ResponseListener(InteractionBroker(), link).__enter__()
        self.root.chmod(0o755)
        try:
            with self.assertRaises(ValueError):
                ResponseListener(InteractionBroker(), self.root / "other.sock").__enter__()
        finally:
            self.root.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
