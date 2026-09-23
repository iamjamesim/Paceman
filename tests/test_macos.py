import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

from service.hub import Store
from service.macos import MacSource


class MacSourceTests(unittest.TestCase):
    def test_lifecycle_and_multiple_sessions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock", computer_name="My Mac") as source:
                self.assertTrue(source.receive(dict(command="agent-event", session="one", turn="1", event="working")))
                self.assertTrue(source.receive(dict(command="agent-event", session="two", turn="2", event="needs-input")))
                value = store.snapshot()
                self.assertEqual(value["mode"], "macos")
                self.assertEqual(value["sourceName"], "My Mac")
                self.assertEqual(value["state"], "needs_input")
                self.assertEqual(len(value["sessions"]), 2)
                self.assertFalse(source.receive(dict(command="agent-event", session="two", turn="old",
                                                     event="working", hook="PostToolUse")))
                self.assertEqual(store.snapshot()["state"], "needs_input")
                self.assertFalse(source.receive(dict(command="agent-event", session="two", turn="2", event="needs-input")))
                self.assertTrue(source.receive(dict(command="agent-event", session="two", turn="2", event="completed")))
                self.assertEqual(store.snapshot()["state"], "working")
                self.assertTrue(source.receive(dict(command="agent-event", session="one", turn="1", event="ended")))
                self.assertEqual(store.snapshot()["state"], "finished")
                last_event = source.last_event_at
            with MacSource(store, socket_path=root / "hook.sock", computer_name="My Mac") as source:
                self.assertEqual(store.snapshot()["state"], "idle")
                self.assertEqual(store.snapshot()["sessions"], [])
                self.assertEqual(source.last_event_at, last_event)

    def test_previous_status_preserves_first_observed_event(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            (root / "status.json").write_text(json.dumps({"mode": "macos", "lastAgentEventAt": 123.5}))
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock") as source:
                self.assertEqual(source.last_event_at, 123.5)

    def test_hook_sends_only_ids_and_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock"):
                result = subprocess.run([sys.executable, "macos/codex_hook.py"],
                    input=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "session-1",
                                      "turn_id": "turn-1", "prompt": "secret prompt"}),
                    env={"PACEMAN_HOOK_SOCKET": str(root / "hook.sock")},
                    capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout, "")
                self.assertEqual(store.snapshot()["state"], "working")
                stopped = subprocess.run([sys.executable, "macos/codex_hook.py"],
                    input=json.dumps({"hook_event_name": "Stop", "session_id": "session-1", "turn_id": "turn-1"}),
                    env={"PACEMAN_HOOK_SOCKET": str(root / "hook.sock")},
                    capture_output=True, text=True, check=True)
                self.assertEqual(json.loads(stopped.stdout), {"continue": True})
                self.assertEqual(store.snapshot()["state"], "finished")
                with store.connect() as db:
                    self.assertNotIn("secret prompt", str([tuple(row) for row in db.execute("SELECT * FROM events")] ))


if __name__ == "__main__":
    unittest.main()
