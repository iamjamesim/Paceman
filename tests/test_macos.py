import json
import os
from pathlib import Path
import plistlib
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from service.codex_limits import codex_binary, parse_codex_allowance, read_codex_allowance
from service.hub import Store
from service.macos import FINISHED_RETENTION, MacSource
from service.push import live_notification
from macos.codex_hook import workspace_label


class MacSourceTests(unittest.TestCase):
    def test_codex_desktop_runtime_is_found_without_cli(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "ChatGPT.app" / "Contents"
            (bundle / "Resources").mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.openai.codex"}))
            binary = bundle / "Resources/codex"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o700)
            with patch.dict(os.environ, {"PACEMAN_CODEX_BIN": ""}):
                self.assertEqual(codex_binary(application_dirs=(root,)), str(binary.resolve()))

    def test_mac_allowance_is_presentation_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            allowance = {"provider": "codex", "remaining": 68, "window": 1,
                         "updatedAt": 1780000000, "resetsAt": 1780600000}
            with MacSource(store, socket_path=root / "hook.sock",
                           allowance_reader=lambda: allowance) as source:
                initial = store.snapshot()
                source.tick()
                source.allowance_thread.join(timeout=2)
                updated = store.snapshot()
                self.assertEqual(updated["allowance"], allowance)
                self.assertEqual(updated["eventID"], initial["eventID"])
                self.assertGreater(updated["revision"], initial["revision"])
                self.assertEqual(updated["state"], "idle")

    def test_mac_allowance_missing_clears_without_new_activity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock",
                           allowance_reader=lambda: None) as source:
                source.allowance = {"provider": "codex", "remaining": 10, "window": 2,
                                    "updatedAt": 1780000000, "resetsAt": 1780000300}
                source.publish_current()
                previous = store.snapshot()
                source.tick()
                source.allowance_thread.join(timeout=2)
                updated = store.snapshot()
                self.assertIsNone(updated["allowance"])
                self.assertEqual(updated["eventID"], previous["eventID"])

    def test_codex_limits_parser_selects_most_depleted_window(self):
        now = 1780000000
        limits = {"rateLimitsByLimitId": {"codex": {"limitId": "codex",
            "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": now + 1000},
            "secondary": {"usedPercent": 61, "windowDurationMins": 10080, "resetsAt": now + 5000}}}}
        self.assertEqual(parse_codex_allowance(limits, now),
                         {"provider": "codex", "remaining": 39, "window": 1,
                          "updatedAt": now, "resetsAt": now + 5000})
        limits["rateLimitsByLimitId"]["codex"]["secondary"]["usedPercent"] = 101
        self.assertIsNone(parse_codex_allowance(limits, now))
        limits["rateLimitsByLimitId"]["codex"]["secondary"]["usedPercent"] = 61
        limits["rateLimitsByLimitId"]["codex"]["secondary"]["resetsAt"] = now - 1
        self.assertIsNone(parse_codex_allowance(limits, now))

    def test_codex_limit_reader_uses_only_chatgpt_account(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "codex"
            binary.write_text("#!/usr/bin/env python3\n"
                "import json, os, sys, time\n"
                "for line in sys.stdin:\n"
                " msg=json.loads(line)\n"
                " if msg.get('id') == 1: result={'userAgent': 'test'}\n"
                " elif msg.get('id') == 2: result={'account': {'type': os.getenv('FAKE_ACCOUNT_TYPE', 'chatgpt')}}\n"
                " elif msg.get('id') == 3: result={'rateLimits': {'limitId': 'codex', "
                "'primary': {'usedPercent': 20, 'windowDurationMins': 300, "
                "'resetsAt': int(time.time()) + 300}}}\n"
                " else: continue\n"
                " print(json.dumps({'id': msg['id'], 'result': result}), flush=True)\n")
            binary.chmod(0o700)
            with patch.dict(os.environ, {"PACEMAN_CODEX_BIN": str(binary)}):
                value = read_codex_allowance()
            self.assertEqual(value["provider"], "codex")
            self.assertEqual(value["remaining"], 80)
            self.assertEqual(value["window"], 2)
            with patch.dict(os.environ, {"PACEMAN_CODEX_BIN": str(binary),
                                              "FAKE_ACCOUNT_TYPE": "apiKey"}):
                self.assertIsNone(read_codex_allowance())

    def test_lifecycle_and_multiple_sessions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            clock = [10.0]
            with MacSource(store, socket_path=root / "hook.sock", computer_name="My Mac",
                           allowance_reader=lambda: None, monotonic=lambda: clock[0]) as source:
                self.assertTrue(source.receive(dict(command="agent-event", session="one", turn="1",
                                                    event="working", workspaceLabel="paceman")))
                self.assertFalse(source.receive(dict(command="agent-event", session="two", turn="2", event="needs-input")))
                self.assertEqual(store.snapshot()["state"], "working")
                clock[0] += 5.1
                source.tick()
                value = store.snapshot()
                self.assertEqual(value["mode"], "macos")
                self.assertEqual(value["sourceName"], "My Mac")
                self.assertEqual(value["state"], "needs_input")
                self.assertEqual(len(value["sessions"]), 2)
                self.assertEqual(next(s for s in value["sessions"] if s.get("workspaceLabel"))["workspaceLabel"], "paceman")
                # The second active session has no workspace, so the grouped
                # Live Activity must not imply both belong to paceman.
                content = live_notification(value, time.time())[0]["aps"]["content-state"]
                self.assertNotIn("workspaceLabel", content)
                self.assertFalse(source.receive(dict(command="agent-event", session="two", turn="old",
                                                     event="working", hook="PostToolUse")))
                self.assertEqual(store.snapshot()["state"], "needs_input")
                self.assertFalse(source.receive(dict(command="agent-event", session="two", turn="2", event="needs-input")))
                self.assertTrue(source.receive(dict(command="agent-event", session="two", turn="2", event="completed")))
                self.assertEqual(store.snapshot()["state"], "working")
                finished = store.snapshot()
                self.assertFalse(source.receive(dict(command="agent-event", session="two", turn="2",
                                                     event="working", hook="PostToolUse")))
                self.assertEqual(store.snapshot()["sessions"], finished["sessions"])
                self.assertTrue(source.receive(dict(command="agent-event", session="one", turn="1", event="ended")))
                self.assertEqual(store.snapshot()["state"], "finished")
                last_event = source.last_event_at
            with MacSource(store, socket_path=root / "hook.sock", computer_name="My Mac") as source:
                self.assertEqual(store.snapshot()["state"], "idle")
                self.assertEqual(store.snapshot()["sessions"], [])
                self.assertEqual(source.last_event_at, last_event)

    def test_short_approval_does_not_publish_attention(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            clock = [10.0]
            with MacSource(store, socket_path=root / "hook.sock",
                           allowance_reader=lambda: None, monotonic=lambda: clock[0]) as source:
                source.receive(dict(command="agent-event", session="one", turn="1", event="working"))
                before = store.snapshot()["revision"]
                self.assertFalse(source.receive(dict(command="agent-event", session="one", turn="1",
                                                     event="needs-input")))
                clock[0] += 4.0
                source.tick()
                self.assertEqual(store.snapshot()["revision"], before)
                self.assertFalse(source.receive(dict(command="agent-event", session="one", turn="1",
                                                     event="working", hook="PostToolUse")))
                clock[0] += 2.0
                source.tick()
                self.assertEqual(store.snapshot()["revision"], before)
                self.assertEqual(store.snapshot()["state"], "working")
                source.receive(dict(command="agent-event", session="one", turn="1", event="needs-input"))
                source.receive(dict(command="agent-event", session="one", turn="1", event="completed"))
                clock[0] += 6.0
                source.tick()
                self.assertEqual(store.snapshot()["state"], "finished")

    def test_blocking_question_needs_input_until_tool_returns(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            clock = [10.0]
            with MacSource(store, socket_path=root / "hook.sock",
                           allowance_reader=lambda: None, monotonic=lambda: clock[0]) as source:
                source.next_allowance_at = float("inf")

                def hook(name, tool_name=None):
                    payload = {"hook_event_name": name, "session_id": "one", "turn_id": "1"}
                    if tool_name:
                        payload["tool_name"] = tool_name
                    subprocess.run([sys.executable, "macos/codex_hook.py"], input=json.dumps(payload),
                                   env={"PACEMAN_HOOK_SOCKET": str(root / "hook.sock")},
                                   capture_output=True, text=True, check=True)

                hook("UserPromptSubmit")
                hook("PreToolUse", "Bash")
                clock[0] += 6
                source.tick()
                self.assertEqual(store.snapshot()["state"], "working")

                hook("PreToolUse", "request_user_input")
                clock[0] += 6
                source.tick()
                self.assertEqual(store.snapshot()["state"], "needs_input")
                hook("PostToolUse", "request_user_input")
                self.assertEqual(store.snapshot()["state"], "working")

    def test_async_question_remains_attention_until_next_user_message(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            clock = [10.0]
            with MacSource(store, socket_path=root / "hook.sock",
                           allowance_reader=lambda: None, monotonic=lambda: clock[0]) as source:
                source.next_allowance_at = float("inf")

                def hook(name, tool_name=None, turn="1"):
                    payload = {"hook_event_name": name, "session_id": "one", "turn_id": turn}
                    if tool_name:
                        payload["tool_name"] = tool_name
                    subprocess.run([sys.executable, "macos/codex_hook.py"], input=json.dumps(payload),
                                   env={"PACEMAN_HOOK_SOCKET": str(root / "hook.sock")},
                                   capture_output=True, text=True, check=True)

                hook("UserPromptSubmit")
                hook("PreToolUse", "request_user_input_async")
                hook("PostToolUse", "request_user_input_async")
                self.assertEqual(store.snapshot()["state"], "working")
                clock[0] += 6
                source.tick()
                self.assertEqual(store.snapshot()["state"], "needs_input")
                hook("PostToolUse", "Bash")
                hook("Stop")
                self.assertEqual(store.snapshot()["state"], "needs_input")
                with store.connect() as db:
                    db.execute("UPDATE mac_sessions SET updated=?",
                               (time.time() - FINISHED_RETENTION - 1,))
                source.tick()
                self.assertEqual(store.snapshot()["state"], "needs_input")
                hook("UserPromptSubmit", turn="2")
                self.assertEqual(store.snapshot()["state"], "working")

    def test_finished_rows_retire_without_expiring_live_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock",
                           allowance_reader=lambda: None) as source:
                source.next_allowance_at = float("inf")
                source.receive(dict(command="agent-event", session="working", turn="1", event="working"))
                source.receive(dict(command="agent-event", session="done", turn="1", event="completed"))
                before = store.snapshot()
                with store.connect() as db:
                    db.execute("UPDATE mac_sessions SET updated=? WHERE state='finished'",
                               (time.time() - FINISHED_RETENTION - 1,))
                source.tick()
                current = store.snapshot()
                self.assertEqual(current["state"], "working")
                self.assertEqual(len(current["sessions"]), 1)
                self.assertEqual(current["eventID"], before["eventID"])
                with store.connect() as db:
                    self.assertEqual(db.execute("SELECT kind FROM events ORDER BY seq DESC LIMIT 1").fetchone()[0],
                                     "presentation")
                source.receive(dict(command="agent-event", session="working", turn="1", event="completed"))
                with store.connect() as db:
                    db.execute("UPDATE mac_sessions SET updated=? WHERE state='finished'",
                               (time.time() - FINISHED_RETENTION - 1,))
                source.tick()
                self.assertEqual(store.snapshot()["state"], "idle")
                self.assertEqual(store.snapshot()["sessions"], [])
                self.assertTrue(source.receive(dict(command="agent-event", session="done", turn="2",
                                                    event="working", hook="UserPromptSubmit")))
                self.assertEqual(store.snapshot()["state"], "working")

    def test_terminal_hook_retries_during_source_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            process = subprocess.Popen([sys.executable, "macos/codex_hook.py"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, env={"PACEMAN_HOOK_SOCKET": str(root / "hook.sock")})
            process.stdin.write(json.dumps({"hook_event_name": "Stop", "session_id": "one",
                                            "turn_id": "1"}))
            process.stdin.close()
            time.sleep(.2)
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None):
                self.assertEqual(process.wait(timeout=2), 0)
                with process.stdout, process.stderr:
                    self.assertEqual(json.loads(process.stdout.read()), {"continue": True})
                self.assertEqual(store.snapshot()["state"], "finished")

    def test_workspace_label_prefers_repository_root_without_a_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "my-project"
            (root / ".git").mkdir(parents=True)
            (root / "src").mkdir()
            self.assertEqual(workspace_label(str(root / "src")), "my-project")
            self.assertIsNone(workspace_label(str(Path.home())))
            self.assertIsNone(workspace_label("relative/project"))

    def test_invalid_optional_workspace_does_not_drop_activity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock") as source:
                self.assertTrue(source.receive(dict(command="agent-event", session="one", turn="1",
                                                    event="working", workspaceLabel="/private/project")))
                self.assertEqual(store.snapshot()["state"], "working")
                self.assertNotIn("workspaceLabel", store.snapshot()["sessions"][0])

    def test_previous_status_preserves_first_observed_event(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            (root / "status.json").write_text(json.dumps({"mode": "macos", "lastAgentEventAt": 123.5}))
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock") as source:
                self.assertEqual(source.last_event_at, 123.5)

    def test_existing_mac_session_table_adds_optional_workspace_column(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with sqlite3.connect(store.path) as db:
                db.execute("CREATE TABLE mac_sessions (id TEXT PRIMARY KEY, turn TEXT NOT NULL, "
                           "state TEXT NOT NULL, updated REAL NOT NULL)")
            with MacSource(store, socket_path=root / "hook.sock") as source:
                self.assertTrue(source.receive(dict(command="agent-event", session="one", turn="1",
                                                    event="working", workspaceLabel="paceman")))
                self.assertEqual(store.snapshot()["sessions"][0]["workspaceLabel"], "paceman")

    def test_hook_sends_short_workspace_label_without_prompt_or_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            project = root / "example-project"
            project.mkdir()
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock"):
                result = subprocess.run([sys.executable, "macos/codex_hook.py"],
                    input=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "session-1",
                                      "turn_id": "turn-1", "cwd": str(project), "prompt": "secret prompt"}),
                    env={"PACEMAN_HOOK_SOCKET": str(root / "hook.sock")},
                    capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout, "")
                self.assertEqual(store.snapshot()["state"], "working")
                self.assertEqual(store.snapshot()["sessions"][0]["workspaceLabel"], "example-project")
                content = live_notification(store.snapshot(), time.time())[0]["aps"]["content-state"]
                self.assertEqual(content["workspaceLabel"], "example-project")
                stopped = subprocess.run([sys.executable, "macos/codex_hook.py"],
                    input=json.dumps({"hook_event_name": "Stop", "session_id": "session-1", "turn_id": "turn-1"}),
                    env={"PACEMAN_HOOK_SOCKET": str(root / "hook.sock")},
                    capture_output=True, text=True, check=True)
                self.assertEqual(json.loads(stopped.stdout), {"continue": True})
                self.assertEqual(store.snapshot()["state"], "finished")
                with store.connect() as db:
                    stored = str([tuple(row) for row in db.execute("SELECT * FROM events")])
                    self.assertNotIn("secret prompt", stored)
                    self.assertNotIn(str(root), stored)


if __name__ == "__main__":
    unittest.main()
