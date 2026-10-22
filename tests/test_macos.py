from contextlib import closing, ExitStack
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from uuid import uuid4

from service.codex_limits import codex_binary, parse_codex_allowances, read_codex_allowances
from service.usage import selected_reading
from service.codex_turns import read_codex_turn_statuses
from service.hub import Store
from service.macos import FINISHED_RETENTION, MacSource
from service.push import live_notification
from macos import codex_hook
from macos.codex_hook import workspace_label


class MacSourceTests(unittest.TestCase):
    def test_idle_observation_uses_recorded_lifecycle_time_without_a_result_or_new_alert(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / 'hub.sqlite3')
            with MacSource(store, socket_path=root / 'hook.sock', allowance_reader=lambda: None,
                           title_reader=lambda _: {}, turn_status_reader=lambda _: {}) as source:
                base = dict(command='agent-event', session='idle-observation', turn='one')
                observed = time.time()
                with patch('service.macos.time.time', return_value=observed):
                    source.receive(dict(base, event='started', hook='SessionStart'))
                before = store.snapshot()
                self.assertEqual(before['sessions'][0]['activityObservedAt'], observed)
                self.assertNotIn('resultObservedAt', before['sessions'][0])
                self.assertFalse(before.get('completedSessions'))
                with patch('service.macos.time.time', return_value=observed + 3600):
                    source.publish_current()
                    after = store.snapshot()
                self.assertEqual(after['sessions'][0]['activityObservedAt'], observed)
                self.assertEqual(after['eventID'], before['eventID'])
                self.assertEqual(after['changedAt'], before['changedAt'])
                source.receive(dict(base, event='working', hook='UserPromptSubmit'))
                self.assertNotIn('activityObservedAt', store.snapshot()['sessions'][0])
                source.receive(dict(base, event='completed', hook='Stop'))
                result = store.snapshot()['sessions'][0]
                self.assertIn('resultObservedAt', result)
                self.assertNotIn('activityObservedAt', result)

    def test_hook_sends_only_transcript_presence_and_transient_classification(self):
        for transient in (True, False):
            payload = dict(hook_event_name='SessionStart', session_id='fork', source='fork',
                           transcript_path=None if transient else '/private/saved.jsonl',
                           prompt='private prompt')
            with patch.object(codex_hook.sys, 'stdin', io.StringIO(json.dumps(payload))), \
                    patch.object(codex_hook.sys, 'stdout', io.StringIO()), \
                    patch.object(codex_hook, 'transient_desktop_fork', return_value=transient), \
                    patch.object(codex_hook, 'deliver') as deliver:
                codex_hook.main()
                message = deliver.call_args.args[0]
                self.assertEqual(message.get('transientDesktopFork'), True if transient else None)
                self.assertEqual(message.get('hasTranscript'), None if transient else True)
                self.assertNotIn('/private', json.dumps(message))
                self.assertNotIn('private prompt', json.dumps(message))

    def test_transient_fork_requires_explicit_hook_metadata_and_desktop_owner(self):
        fork = dict(hook_event_name='SessionStart', source='fork', transcript_path=None)
        with patch.object(codex_hook.sys, 'platform', 'darwin'), \
                patch.object(codex_hook, 'desktop_owned_runtime', return_value=True) as desktop:
            self.assertTrue(codex_hook.transient_desktop_fork(fork))
            for changed in [dict(fork, transcript_path='/private/saved.jsonl'),
                            dict(fork, transcript_path=''), dict(fork, source='startup'),
                            dict(fork, hook_event_name='Stop'),
                            {k: v for k, v in fork.items() if k != 'transcript_path'}]:
                self.assertFalse(codex_hook.transient_desktop_fork(changed))
            self.assertEqual(desktop.call_count, 1)
        with patch.object(codex_hook.sys, 'platform', 'darwin'), \
                patch.object(codex_hook, 'desktop_owned_runtime', return_value=False):
            self.assertFalse(codex_hook.transient_desktop_fork(fork), 'User CLI forks remain visible')

    def test_desktop_runtime_requires_direct_app_parent_and_keeps_arguments_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Codex.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
                dict(CFBundleIdentifier='com.openai.codex', CFBundleExecutable='Codex')))
            runtime = app / 'Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
            owner = app / 'Contents/MacOS/Codex'
            processes = {10: (20, Path('/bin/sh')), 20: (30, runtime), 30: (1, owner)}
            self.assertTrue(codex_hook.desktop_owned_runtime(pid=10, reader=processes.__getitem__))
            for parent in [Path('/bin/zsh'), Path('/usr/bin/python3')]:
                processes[30] = (1, parent)
                self.assertFalse(codex_hook.desktop_owned_runtime(pid=10, reader=processes.__getitem__))
            processes[30] = (1, owner)
            processes[20] = (30, Path('/usr/local/bin/codex'))
            self.assertFalse(codex_hook.desktop_owned_runtime(pid=10, reader=processes.__getitem__))
            with patch.object(codex_hook.subprocess, 'run', side_effect=OSError):
                self.assertFalse(codex_hook.desktop_owned_runtime())
            with patch.object(codex_hook.subprocess, 'run', return_value=subprocess.CompletedProcess(
                    [], 0, '20 /private/Codex App/codex\n', '')) as run:
                self.assertEqual(codex_hook.process_identity(10), (20, Path('/private/Codex App/codex')))
                self.assertEqual(run.call_args.args[0][-1], 'ppid=,comm=')

    def test_transient_desktop_forks_never_publish_activity_or_history_across_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / 'hub.sqlite3')
            session = str(uuid4())
            base = dict(command='agent-event', session=session, turn='one')
            def source():
                return MacSource(store, socket_path=root / 'hook.sock', allowance_reader=lambda: None,
                                 title_reader=lambda _: {}, turn_status_reader=lambda _: {})
            with source() as first:
                before = store.snapshot()
                self.assertFalse(first.receive(dict(base, event='started', hook='SessionStart', transientDesktopFork=True)))
                for event, hook in [('working', 'UserPromptSubmit'), ('needs-input', 'PermissionRequest'),
                                    ('completed', 'Stop'), ('ended', 'SessionEnd'), ('completed', 'Stop')]:
                    self.assertFalse(first.receive(dict(base, event=event, hook=hook)))
                self.assertEqual(store.snapshot()['revision'], before['revision'])
                self.assertEqual(first.last_event_at, 0)
                self.assertFalse(first.native_sessions())
                self.assertFalse(first.pending_attention)
            with source() as restored:
                restored.receive(dict(base, event='completed', hook='Stop'))
                snapshot = store.snapshot()
                self.assertFalse(snapshot.get('sessions'))
                self.assertFalse(snapshot.get('completedSessions'))
                with store.connect() as db:
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM mac_codex_visibility').fetchone()[0], 1)
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM mac_codex_tracking').fetchone()[0], 0)
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM completed_sessions').fetchone()[0], 0)

    def test_late_transient_classification_cleans_only_matching_session_and_saved_evidence_wins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / 'hub.sqlite3')
            with MacSource(store, socket_path=root / 'hook.sock', allowance_reader=lambda: None,
                           title_reader=lambda _: {}, turn_status_reader=lambda _: {}) as source:
                base = dict(command='agent-event', session='internal', turn='one')
                real = dict(base, session='real')
                source.receive(dict(real, event='working', hook='UserPromptSubmit', hasTranscript=True))
                source.receive(dict(base, event='completed', hook='Stop'))
                with store.connect() as db:
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM completed_sessions').fetchone()[0], 1)
                source.receive(dict(base, event='started', hook='SessionStart', transientDesktopFork=True))
                self.assertEqual(len(store.snapshot()['sessions']), 1)
                self.assertFalse(store.snapshot().get('completedSessions'))
                self.assertEqual(source.native_sessions(), ['real'])
                # Materialization promotes the exact session; late starts cannot hide it again.
                source.receive(dict(base, event='working', hook='UserPromptSubmit', hasTranscript=True))
                source.receive(dict(base, event='started', hook='SessionStart', transientDesktopFork=True))
                self.assertEqual(len(store.snapshot()['sessions']), 2)
                # An unknown/older hook without classification retains ordinary behavior.
                source.receive(dict(base, session='unknown', event='completed', hook='Stop'))
                self.assertEqual(len(store.snapshot()['sessions']), 3)

    def test_codex_visibility_metadata_expires_and_stays_bounded(self):
        from service.macos import CODEX_VISIBILITY_RETENTION, MAX_CODEX_VISIBILITY
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / 'hub.sqlite3')
            with MacSource(store, socket_path=root / 'hook.sock', allowance_reader=lambda: None) as source:
                now = time.time()
                with store.connect() as db:
                    db.executemany('INSERT INTO mac_codex_visibility VALUES (?,?,?)',
                        [(str(i), i % 2, now - i) for i in range(MAX_CODEX_VISIBILITY + 2)])
                    db.execute('INSERT INTO mac_codex_visibility VALUES (?,?,?)',
                        ('expired', 0, now - CODEX_VISIBILITY_RETENTION))
                    source._prune_codex_visibility(db)
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM mac_codex_visibility').fetchone()[0], MAX_CODEX_VISIBILITY)
                    self.assertIsNone(db.execute("SELECT 1 FROM mac_codex_visibility WHERE id='expired'").fetchone())

    def test_claude_native_resolution_clears_only_matching_live_tool_waits(self):
        from macos.claude_hook import message_for
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / 'hub.sqlite3')
            with MacSource(store, socket_path=root / 'hook.sock', providers=('claude',),
                           allowance_reader=lambda: None, turn_status_reader=lambda _: {},
                           monotonic=lambda: 100) as source:
                base = dict(session_id='native-local', prompt_id='turn')
                def hook(event, **fields):
                    source.receive(message_for(dict(base, hook_event_name=event, **fields)))
                key = hashlib.sha256(b'claude:native-local').hexdigest()
                hook('UserPromptSubmit')
                hook('PreToolUse', tool_name='Bash', tool_use_id='a')
                hook('PreToolUse', tool_name='Bash', tool_use_id='b')
                hook('PermissionRequest', tool_name='Bash')
                hook('Elicitation', elicitation_id='form')
                current = source.claude_sessions[key]
                permission = 'permission:' + hashlib.sha256(b'Bash').hexdigest()
                input_wait = 'input:' + hashlib.sha256(b'form').hexdigest()
                source.native_claude_requests_changed(key, 'turn', True)
                source.native_claude_requests_resolved(key, 'turn', [('a', 'Bash')], {'Bash'})
                self.assertIn(permission, current.waits, 'Sibling permission is still pending')
                source.native_claude_requests_resolved(key, 'old-turn', [('b', 'Bash')], set())
                self.assertIn(permission, current.waits)
                source.native_claude_requests_resolved(key, 'turn', [('unknown', 'Bash')], set())
                self.assertIn(permission, current.waits)
                source.native_claude_requests_resolved(key, 'turn', [('b', 'Bash')], set())
                source.native_claude_requests_changed(key, 'turn', False)
                self.assertNotIn(permission, current.waits)
                self.assertIn(input_wait, current.waits, 'Unrelated input is not an approval')
                self.assertIn('b', current.tools, 'Approving does not finish the tool')
                hook('PreToolUse', tool_name='AskUserQuestion', tool_use_id='q')
                source.native_claude_requests_resolved(key, 'turn', [('q', 'AskUserQuestion')], set())
                self.assertNotIn('question:q', current.waits)
                hook('ElicitationResult', elicitation_id='form')
                self.assertEqual(store.snapshot()['state'], 'working')

    def test_native_request_state_is_turn_scoped_and_disconnect_is_not_an_answer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / 'hub.sqlite3')
            with MacSource(store, socket_path=root / 'hook.sock', allowance_reader=lambda: None,
                           turn_status_reader=lambda _: {}) as source:
                base = dict(command='agent-event', session='one', turn='1')
                source.receive(dict(base, event='working', hook='UserPromptSubmit'))
                source.native_requests_changed('one', {'1': True})
                self.assertEqual(store.snapshot()['state'], 'needs_input')
                source.receive(dict(base, event='working', hook='PostToolUse', toolID='other'))
                self.assertEqual(store.snapshot()['state'], 'needs_input')
                source.native_requests_changed('one', None)
                self.assertEqual(store.snapshot()['state'], 'needs_input')
                source.native_requests_changed('one', {'1': False})
                self.assertEqual(store.snapshot()['state'], 'working')
                source.native_requests_changed('one', {'1': True})
                source.receive(dict(base, event='completed', hook='Stop'))
                self.assertEqual(store.snapshot()['state'], 'needs_input')
                source.native_requests_changed('one', {'1': True})
                self.assertEqual(store.snapshot()['state'], 'needs_input')
                source.native_requests_changed('one', {'1': 'planImplementation'})
                self.assertEqual(store.snapshot()['state'], 'needs_input')
                self.assertEqual(source.native_response_sessions(), {'one': '1'}, 'Finished turns retain their response binding')
                with store.connect() as db:
                    db.execute('UPDATE mac_sessions SET updated=?', (time.time() - FINISHED_RETENTION - 1,))
                source.tick()
                self.assertEqual(store.snapshot()['state'], 'needs_input', 'An unanswered plan does not retire as finished')
                source.native_requests_changed('one', {'1': False})
                self.assertEqual(store.snapshot()['state'], 'finished')
                source.tick()
                self.assertEqual(store.snapshot()['state'], 'finished', 'Resolving an older plan starts the normal result retention')
                source.receive(dict(base, turn='2', event='working', hook='UserPromptSubmit'))
                self.assertEqual(store.snapshot()['state'], 'working')
                source.native_requests_changed('one', {'2': 'planImplementation'})
                source.receive(dict(base, turn='2', event='completed', hook='Stop'))
                self.assertEqual(store.snapshot()['state'], 'needs_input', 'Stop may arrive after the plan decision')
                source.native_requests_changed('one', {'2': False})
                self.assertEqual(store.snapshot()['state'], 'finished')
    def test_resumed_turn_uses_saved_order_and_replays_approval_lifecycle(self):
        cases = [
            ([("needs-input", "PermissionRequest")], "interrupted", "needs_input"),
            ([("needs-input", "PermissionRequest"), ("working", "PostToolUse")], "interrupted", "needs_input"),
            ([("question-opened", "PreToolUse"), ("working", "PostToolUse")], "interrupted", "needs_input"),
            ([("needs-input", "PermissionRequest"), ("completed", "Stop")], "completed", "finished"),
            ([("needs-input", "PermissionRequest")], "failed", "failed"),
        ]
        for events, outcome, expected in cases:
            with self.subTest(events=events, outcome=outcome), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                root.chmod(0o700)
                clock = [10.0]
                store = Store(root / "hub.sqlite3")
                with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                        turn_status_reader=lambda _: {}, monotonic=lambda: clock[0],
                        turn_metadata_reader=lambda _: {"one": [{"id": "resume", "status": outcome},
                                                                {"id": "old", "status": "interrupted"}]}) as source:
                    source.next_allowance_at = source.next_turn_status_at = source.next_turn_recovery_at = float("inf")
                    base = dict(command="agent-event", session="one")
                    source.receive(dict(base, turn="old", event="working", hook="UserPromptSubmit"))
                    source.receive(dict(base, turn="old", event="interrupted", hook="Interrupt"))
                    for event, hook in events:
                        source.receive(dict(base, turn="resume", event=event, hook=hook))
                    self.assertEqual(store.snapshot()["state"], "idle")
                    source._recover_turns(list(source.pending_turn_events.items()))
                    clock[0] += 6
                    source.tick()
                    self.assertEqual(store.snapshot()["state"], expected)
                    source.receive(dict(base, turn="old", event="needs-input", hook="PermissionRequest"))
                    source._recover_turns(list(source.pending_turn_events.items()))
                    clock[0] += 6
                    source.tick()
                    self.assertEqual(store.snapshot()["state"], expected)
                    self.assertFalse(source.pending_turn_events)

    def test_resume_verification_retries_and_does_not_resurrect_invalidated_session(self):
        for invalidate in ("prompt", "end", "disable", None):
            with self.subTest(invalidate=invalidate), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                root.chmod(0o700)
                store = Store(root / "hub.sqlite3")
                with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                               turn_status_reader=lambda _: {}, turn_metadata_reader=lambda _: {}) as source:
                    base = dict(command="agent-event", session="one")
                    source.receive(dict(base, turn="old", event="working", hook="UserPromptSubmit"))
                    source.receive(dict(base, turn="resume", event="needs-input", hook="PermissionRequest"))
                    tracked = list(source.pending_turn_events.items())
                    source._recover_turns(tracked)
                    self.assertTrue(source.pending_turn_events)  # Unavailable metadata is not evidence.
                    if invalidate == "prompt":
                        source.receive(dict(base, turn="newer", event="working", hook="UserPromptSubmit"))
                    elif invalidate == "end":
                        source.receive(dict(base, turn="", event="ended", hook="SessionEnd"))
                    elif invalidate == "disable":
                        source.settings_reader = lambda: ["claude"]
                        source._apply_settings()
                    source.turn_metadata_reader = lambda _: {"one": [{"id": "resume", "status": "interrupted"}]}
                    source._recover_turns(tracked)
                    if invalidate is None:
                        self.assertTrue(source.pending_attention)
                    else:
                        self.assertFalse(source.pending_attention)
                        self.assertFalse(source.pending_turn_events)

    def test_new_hook_during_metadata_read_is_retained_for_next_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                           turn_status_reader=lambda _: {}) as source:
                base = dict(command="agent-event", session="one")
                source.receive(dict(base, turn="old", event="working", hook="UserPromptSubmit"))
                source.receive(dict(base, turn="resume", event="working", hook="PostToolUse"))
                def read(_):
                    source.receive(dict(base, turn="newer", event="needs-input", hook="PermissionRequest"))
                    return {"one": [{"id": "resume", "status": "interrupted"}, {"id": "old"}]}
                source.turn_metadata_reader = read
                source._recover_turns(list(source.pending_turn_events.items()))
                batch = next(iter(source.pending_turn_events.values()))
                self.assertEqual(batch["previous"], "resume")
                self.assertEqual([event["turn"] for event in batch["events"]], ["newer"])
                source.turn_metadata_reader = lambda _: {"one": [{"id": "newer", "status": "interrupted"},
                                                                 {"id": "resume"}]}
                source._recover_turns(list(source.pending_turn_events.items()))
                self.assertTrue(source.pending_attention)
                self.assertFalse(source.pending_turn_events)

    def test_codex_turn_reader_requests_status_without_items(self):
        with tempfile.TemporaryDirectory() as temporary:
            session, turn = str(uuid4()), str(uuid4())
            binary = Path(temporary) / "codex"
            binary.write_text("#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "for line in sys.stdin:\n"
                " msg=json.loads(line)\n"
                " if msg.get('id') == 1: result={'userAgent': 'test'}\n"
                " elif msg.get('id') == 2:\n"
                "  p=msg['params']\n"
                "  assert p['itemsView']=='notLoaded' and p['threadId']==os.environ['TEST_SESSION']\n"
                "  result={'data':[{'id':os.environ['TEST_TURN'],'status':'failed','items':[]}]}\n"
                " else: continue\n"
                " print(json.dumps({'id':msg['id'],'result':result}),flush=True)\n")
            binary.chmod(0o700)
            with patch.dict(os.environ, {"PACEMAN_CODEX_BIN": str(binary),
                                              "TEST_SESSION": session, "TEST_TURN": turn}):
                self.assertEqual(read_codex_turn_statuses([(session, turn)]),
                                 {(session, turn): "failed"})

    def test_terminal_failure_corrects_stop_and_ignores_late_hook(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            session, turn = str(uuid4()), str(uuid4())
            reader = lambda turns: {(session, turn): "failed"}
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                           turn_status_reader=reader) as source:
                event = dict(command="agent-event", session=session, turn=turn)
                source.receive({**event, "event": "working", "hook": "UserPromptSubmit"})
                source.receive({**event, "event": "completed", "hook": "Stop"})
                self.assertEqual(store.snapshot()["state"], "finished")
                source._refresh_turn_statuses(list(source.turn_ids.items()))
                self.assertEqual(store.snapshot()["state"], "failed")
                self.assertEqual(store.snapshot()["sessions"][0]["state"], "failed")
                source.receive({**event, "event": "completed", "hook": "Stop"})
                self.assertEqual(store.snapshot()["state"], "failed")
                source.receive({**event, "turn": str(uuid4()), "event": "working",
                                "hook": "UserPromptSubmit"})
                self.assertEqual(store.snapshot()["state"], "working")

    def test_terminal_failure_without_stop_does_not_stay_working(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            session, turn = str(uuid4()), str(uuid4())
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                           turn_status_reader=lambda turns: {(session, turn): "failed"}) as source:
                source.receive(dict(command="agent-event", session=session, turn=turn,
                                    event="working", hook="UserPromptSubmit"))
                source._refresh_turn_statuses(list(source.turn_ids.items()))
                self.assertEqual(store.snapshot()["state"], "failed")

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

    def test_current_desktop_runtime_precedes_legacy_and_cli(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "ChatGPT.app" / "Contents"
            binary = bundle / "Resources/codex-cli/bin/codex"
            binary.parent.mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.openai.codex"}))
            legacy = bundle / "Resources/codex"
            cli = root / "codex"
            for path in (binary, legacy, cli):
                path.write_text("#!/bin/sh\nexit 0\n")
                path.chmod(0o700)
            with patch.dict(os.environ, {"PACEMAN_CODEX_BIN": ""}), \
                    patch("service.codex_limits.shutil.which", return_value=str(cli)):
                self.assertEqual(codex_binary(application_dirs=(root,)), str(binary.resolve()))
                binary.chmod(0o600)
                self.assertEqual(codex_binary(application_dirs=(root,)), str(legacy.resolve()))
            with patch.dict(os.environ, {"PACEMAN_CODEX_BIN": str(cli)}):
                binary.chmod(0o700)
                self.assertEqual(codex_binary(application_dirs=(root,)), str(cli.resolve()))

    def test_provider_changes_preserve_other_activity_and_codex_usage(self):
        from macos.claude_hook import message_for
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            providers = [["codex"]]
            quota = dict(provider="codex",remaining=68,window=1,updatedAt=1780000000,resetsAt=1780600000)
            with MacSource(store, socket_path=root / "hook.sock", providers=["codex"],
                           settings_reader=lambda: providers[0], allowance_reader=lambda: [quota],
                           turn_status_reader=lambda _: {}) as source:
                source.receive(dict(command="agent-event",session=str(uuid4()),turn=str(uuid4()),
                                    event="working",hook="UserPromptSubmit"))
                source.tick(); source.allowance_thread.join(timeout=2)
                original = store.snapshot()
                providers[0] = ["codex", "claude"]
                source.tick()
                self.assertEqual(store.snapshot()["sessions"], original["sessions"])
                self.assertEqual(store.snapshot()["eventID"], original["eventID"])
                event = message_for(dict(hook_event_name="UserPromptSubmit",session_id="claude",prompt_id="one"))
                self.assertTrue(source.receive(event))
                self.assertEqual(len(store.snapshot()["sessions"]), 2)
                self.assertEqual(store.snapshot()["allowances"], [quota])
                providers[0] = ["codex"]
                source.tick()
                self.assertEqual(store.snapshot()["sessions"], original["sessions"])
                self.assertEqual(store.snapshot()["allowances"], [quota])
                self.assertFalse(source.receive(event))
                providers[0] = []
                source.tick()
                self.assertEqual(store.snapshot()["sessions"], [])
                self.assertEqual(store.snapshot()["allowances"], [])
                self.assertFalse(source.closed)

    def test_claude_only_monitors_activity_without_reading_usage(self):
        from macos.claude_hook import message_for
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            reader = Mock()
            with MacSource(store, socket_path=root / "hook.sock", providers=("claude",),
                           allowance_reader=reader) as source:
                source.receive(message_for({"hook_event_name": "UserPromptSubmit", "session_id": "claude", "prompt_id": "one"}))
                source.tick()
                reader.assert_not_called()
                self.assertEqual(store.snapshot()["state"], "working")
                self.assertEqual(store.snapshot()["allowances"], [])

    def test_disabled_codex_rejects_an_inflight_quota_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            providers = [["codex", "claude"]]
            entered, release = threading.Event(), threading.Event()
            def read():
                entered.set(); release.wait(3)
                return dict(provider="codex",remaining=68,window=1,updatedAt=1780000000,resetsAt=1780600000)
            with MacSource(store,socket_path=root/'hook.sock',settings_reader=lambda: providers[0],
                           allowance_reader=read,turn_status_reader=lambda _: {}) as source:
                try:
                    source.tick(); self.assertTrue(entered.wait(2))
                    providers[0] = ["claude"]
                    source.tick()
                finally:
                    release.set(); source.allowance_thread.join(timeout=2)
                self.assertEqual(store.snapshot()["allowances"], [])

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
        self.assertEqual(selected_reading(parse_codex_allowances(limits, now)),
                         {"provider": "codex", "remaining": 39, "window": 1,
                          "windowDurationMins": 10080,
                          "updatedAt": now, "resetsAt": now + 5000})
        limits["rateLimitsByLimitId"]["codex"]["primary"]["usedPercent"] = 61
        self.assertEqual(selected_reading(parse_codex_allowances(limits, now))["window"], 1)
        limits["rateLimitsByLimitId"]["codex"]["primary"]["usedPercent"] = 25
        limits["rateLimitsByLimitId"]["codex"]["secondary"]["usedPercent"] = 101
        self.assertIsNone(selected_reading(parse_codex_allowances(limits, now)))
        limits["rateLimitsByLimitId"]["codex"]["secondary"]["usedPercent"] = 61
        limits["rateLimitsByLimitId"]["codex"]["secondary"]["resetsAt"] = now - 1
        self.assertIsNone(selected_reading(parse_codex_allowances(limits, now)))

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
                values = read_codex_allowances()
            self.assertEqual(len(values), 1)
            value = values[0]
            self.assertEqual(value["provider"], "codex")
            self.assertEqual(value["remaining"], 80)
            self.assertEqual(value["window"], 2)
            with patch.dict(os.environ, {"PACEMAN_CODEX_BIN": str(binary),
                                              "FAKE_ACCOUNT_TYPE": "apiKey"}):
                self.assertEqual(read_codex_allowances(), [])

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
                self.assertNotIn("mode", value)
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
                self.assertEqual(store.snapshot()["state"], "finished")
                self.assertEqual(len(store.snapshot()["sessions"]), 1)
                self.assertEqual(source.last_event_at, last_event)

    def test_multiple_approvals_survive_unrelated_work_before_and_after_debounce(self):
        for published in (False, True):
            with self.subTest(published=published), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                root.chmod(0o700)
                store = Store(root / "hub.sqlite3")
                clock = [10.0]
                with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                               turn_status_reader=lambda _: {}, monotonic=lambda: clock[0]) as source:
                    source.next_turn_status_at = float("inf")
                    base = dict(command="agent-event", session="one", turn="1")
                    source.receive(dict(base, event="working", hook="UserPromptSubmit"))
                    for token in ("approval-a", "approval-b"):
                        source.receive(dict(base, event="needs-input", hook="PermissionRequest",
                                            approvalToken=token, attentionKey="same-command"))
                    if published:
                        clock[0] += 6
                        source.tick()
                        self.assertEqual(store.snapshot()["state"], "needs_input")
                    source.receive(dict(base, event="working", hook="UserPromptSubmit"))
                    source.receive(dict(base, event="working", hook="PostToolUse", attentionKey="other-command", toolID="unrelated"))
                    clock[0] += 6
                    source.tick()
                    self.assertEqual(store.snapshot()["state"], "needs_input")
                    source.receive(dict(base, event="working", hook="PostToolUse", attentionKey="same-command", toolID="call-a"))
                    self.assertEqual(store.snapshot()["state"], "needs_input")
                    # A duplicate completion cannot consume the second identical approval.
                    source.receive(dict(base, event="working", hook="PostToolUse", attentionKey="same-command", toolID="call-a"))
                    self.assertEqual(store.snapshot()["state"], "needs_input")
                    source.receive(dict(base, event="working", hook="PostToolUse", attentionKey="same-command", toolID="call-b"))
                    self.assertEqual(store.snapshot()["state"], "working")
                    self.assertFalse(source.pending_attention)
                    self.assertFalse(source.approval_calls)

    def test_unidentified_approval_needs_authoritative_resolution_not_other_tool_activity(self):
        for ending in ("completed", "interrupted", "ended", "new-turn", "disable"):
            with self.subTest(ending=ending), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                root.chmod(0o700)
                store = Store(root / "hub.sqlite3")
                clock = [10.0]
                with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                               turn_status_reader=lambda _: {}, monotonic=lambda: clock[0]) as source:
                    source.next_turn_status_at = float("inf")
                    base = dict(command="agent-event", session="one", turn="1")
                    source.receive(dict(base, event="working", hook="UserPromptSubmit"))
                    source.receive(dict(base, event="needs-input", hook="PermissionRequest"))
                    source.receive(dict(base, event="working", hook="PostToolUse"))
                    clock[0] += 6
                    source.tick()
                    self.assertEqual(store.snapshot()["state"], "needs_input")
                    if ending == "new-turn":
                        source.receive({**base, "turn": "2", "event": "working", "hook": "UserPromptSubmit"})
                    elif ending == "disable":
                        source.settings_reader = lambda: ["claude"]
                        source._apply_settings()
                    else:
                        source.receive(dict(base, event=ending))
                    self.assertFalse(source.pending_attention)
                    self.assertFalse(source.approval_calls)
                    self.assertNotEqual(store.snapshot()["state"], "needs_input")

    def test_approval_correlation_is_metadata_only_and_shell_reason_is_not_identity(self):
        base = dict(tool_name="Bash", cwd="/private/project")
        first = codex_hook.attention_key(dict(base, tool_input={"command": "secret command", "description": "Approval reason"}))
        second = codex_hook.attention_key(dict(base, tool_input={"command": "secret command"}))
        self.assertEqual(first, second)
        self.assertEqual(len(first), 64)
        self.assertNotIn("secret", first)
        self.assertNotEqual(first, codex_hook.attention_key(dict(base, tool_input={"command": "different command"})))
        self.assertNotEqual(codex_hook.attention_key(dict(tool_name="mcp__x__write", tool_input={"description": "A"})),
                            codex_hook.attention_key(dict(tool_name="mcp__x__write", tool_input={"description": "B"})))

    def test_permission_hook_correlates_completions_without_sending_command_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            clock = [10.0]
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                           turn_status_reader=lambda _: {}, monotonic=lambda: clock[0]) as source:
                source.next_turn_status_at = float("inf")
                def hook(name, command="private command", call=None):
                    payload = dict(hook_event_name=name, session_id="one", turn_id="1", tool_name="Bash",
                                   tool_input={"command": command})
                    if call:
                        payload["tool_use_id"] = call
                    subprocess.run([sys.executable, "macos/codex_hook.py"], input=json.dumps(payload),
                                   env={"PACEMAN_HOOK_SOCKET": str(root / "hook.sock")},
                                   capture_output=True, text=True, check=True)
                hook("UserPromptSubmit")
                hook("PermissionRequest")
                hook("PermissionRequest")
                clock[0] += 6
                source.tick()
                hook("PostToolUse", "unrelated", "other-call")
                self.assertEqual(store.snapshot()["state"], "needs_input")
                self.assertNotIn("private command", json.dumps(source.approval_calls))
                content = live_notification(store.snapshot(), time.time())[0]["aps"]["content-state"]
                self.assertEqual(content["needsInput"], 1)
                hook("PostToolUse", call="call-a")
                self.assertEqual(store.snapshot()["state"], "needs_input")
                hook("PostToolUse", call="call-b")
                self.assertEqual(store.snapshot()["state"], "working")

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
                                                     event="needs-input", attentionKey="matching", approvalToken="approval")))
                clock[0] += 4.0
                source.tick()
                self.assertEqual(store.snapshot()["revision"], before)
                self.assertFalse(source.receive(dict(command="agent-event", session="one", turn="1",
                                                     event="working", hook="PostToolUse", attentionKey="matching", toolID="matching-call")))
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

    def test_phone_answer_clears_only_its_question_and_never_reopens_a_finished_turn(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); root.chmod(0o700)
            store = Store(root / "hub.sqlite3"); clock = [10.0]
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                           turn_status_reader=lambda _: {}, monotonic=lambda: clock[0]) as source:
                source.next_allowance_at = source.next_turn_status_at = float("inf")
                base = dict(command="agent-event", session="one", turn="1")
                source.receive(dict(base, event="working", hook="UserPromptSubmit"))
                for call in ("call-a", "call-b"):
                    source.receive(dict(base, event="question-opened", toolID=call))
                clock[0] += 6; source.tick()
                self.assertEqual(store.snapshot()["state"], "needs_input")
                for change in ({"turn": "old", "toolID": "call-a"}, {"toolID": "other"},
                               {"session": "another", "toolID": "call-a"}):
                    source.receive({**base, "event": "question-answered", **change})
                    self.assertEqual(store.snapshot()["state"], "needs_input")
                source.receive(dict(base, event="question-answered", toolID="call-a"))
                self.assertEqual(store.snapshot()["state"], "needs_input")
                source.receive(dict(base, event="question-answered", toolID="call-b"))
                self.assertEqual(store.snapshot()["state"], "working")
                self.assertFalse(source.pending_questions)
                self.assertFalse(source.question_calls)
                source.receive(dict(base, event="completed", hook="Stop"))
                source.receive(dict(base, event="question-answered", toolID="call-b"))
                self.assertEqual(store.snapshot()["state"], "finished")
                self.assertEqual(len(store.snapshot()["sessions"]), 1)

    def test_resumed_question_answer_recovers_with_its_original_tool_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                           turn_status_reader=lambda _: {}, turn_metadata_reader=lambda _: {
                               "one": [{"id": "new", "status": "inProgress"},
                                       {"id": "old", "status": "interrupted"}]}) as source:
                source.next_allowance_at = source.next_turn_status_at = float("inf")
                base = dict(command="agent-event", session="one")
                source.receive(dict(base, turn="old", event="working", hook="UserPromptSubmit"))
                source.receive(dict(base, turn="old", event="interrupted", hook="Interrupt"))
                source.receive(dict(base, turn="new", event="question-opened", toolID="call-a"))
                source.receive(dict(base, turn="new", event="question-answered", toolID="call-a"))
                source._recover_turns(list(source.pending_turn_events.items()))
                self.assertEqual(store.snapshot()["state"], "working")
                self.assertFalse(source.pending_questions)
                self.assertFalse(source.question_calls)

    def test_async_question_ends_with_completed_turn(self):
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
                self.assertEqual(store.snapshot()["state"], "needs_input")
                hook("Stop")
                self.assertEqual(store.snapshot()["state"], "finished")
                self.assertFalse(source.pending_questions)
                hook("PreToolUse", "request_user_input_async")
                hook("PermissionRequest")
                hook("UserPromptSubmit")
                clock[0] += 6
                source.tick()
                self.assertEqual(store.snapshot()["state"], "finished")
                with store.connect() as db:
                    key = db.execute("SELECT id FROM mac_sessions").fetchone()[0]
                source.pending_questions[key] = ("1", clock[0] - 1, None)
                source.publish_current()
                self.assertEqual(store.snapshot()["state"], "finished")
                later = time.time() + FINISHED_RETENTION + 1
                with patch('service.macos.time.time', return_value=later):
                    source.tick()
                    self.assertEqual(store.snapshot()["state"], "idle")
                self.assertFalse(source.pending_questions)
                hook("UserPromptSubmit", turn="2")
                self.assertEqual(store.snapshot()["state"], "working")

    def test_completed_turn_status_clears_async_question_without_stop(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            session, turn = str(uuid4()), str(uuid4())
            clock = [10.0]
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None,
                           turn_status_reader=lambda turns: {(session, turn): "completed"},
                           monotonic=lambda: clock[0]) as source:
                event = dict(command="agent-event", session=session, turn=turn)
                source.receive({**event, "event": "working", "hook": "UserPromptSubmit"})
                source.receive({**event, "event": "question-opened", "hook": "PreToolUse"})
                clock[0] += 6
                source.publish_current()
                self.assertEqual(store.snapshot()["state"], "needs_input")
                source._refresh_turn_statuses(list(source.turn_ids.items()))
                self.assertEqual(store.snapshot()["state"], "finished")
                self.assertFalse(source.pending_questions)

    def test_finished_rows_retire_without_expiring_live_work(self):
        clock = [time.time()]
        with tempfile.TemporaryDirectory() as temporary, patch('service.macos.time.time', side_effect=lambda: clock[0]):
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")
            with MacSource(store, socket_path=root / "hook.sock", allowance_reader=lambda: None) as source:
                source.next_allowance_at = float("inf")
                source.receive(dict(command="agent-event", session="working", turn="1", event="working"))
                source.receive(dict(command="agent-event", session="done", turn="1", event="completed"))
                before = store.snapshot()
                clock[0] += FINISHED_RETENTION + 1
                source.tick()
                current = store.snapshot()
                self.assertEqual(current["state"], "working")
                self.assertEqual(len(current["sessions"]), 1)
                self.assertEqual(len(current["completedSessions"]), 1)
                self.assertEqual(current["eventID"], before["eventID"])
                with store.connect() as db:
                    self.assertEqual(db.execute("SELECT kind FROM events ORDER BY seq DESC LIMIT 1").fetchone()[0], "presentation")
                source.receive(dict(command="agent-event", session="working", turn="1", event="completed"))
                clock[0] += FINISHED_RETENTION + 1
                source.tick()
                self.assertEqual(store.snapshot()["state"], "idle")
                self.assertEqual(store.snapshot()["sessions"], [])
                self.assertEqual(len(store.snapshot()["completedSessions"]), 2)
                source.receive(dict(command="agent-event", session="done", turn="2", event="working", hook="UserPromptSubmit"))
                self.assertEqual(store.snapshot()["state"], "working")
                self.assertEqual(len(store.snapshot()["completedSessions"]), 1)

    def test_terminal_hook_retries_during_source_restart(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary)
            root.chmod(0o700)
            store = Store(root / "hub.sqlite3")

            def restart(delay):
                self.assertEqual(delay, .1)
                stack.enter_context(MacSource(store, socket_path=root / "hook.sock",
                                              allowance_reader=lambda: None))

            # Start the receiver only after a real failed connection. Control
            # the retry clock so runner scheduling cannot exhaust its budget.
            with patch.object(codex_hook, "time") as clock:
                clock.monotonic.return_value = 0.0
                clock.sleep.side_effect = restart
                codex_hook.deliver(dict(command="agent-event", session="one", turn="1",
                                        event="completed", hook="Stop"), root / "hook.sock", "Stop")
                clock.sleep.assert_called_once_with(.1)
            self.assertEqual(store.snapshot()["state"], "finished")

    def test_hook_retry_budget_is_bounded_and_only_for_terminal_events(self):
        for event in ("Stop", "Interrupt", "SessionEnd", "UserPromptSubmit"):
            with self.subTest(event=event), patch.object(codex_hook, "time") as clock, \
                    patch.object(codex_hook.socket, "socket") as socket_factory:
                now = [0.0]

                def advance(delay):
                    now[0] += delay

                clock.monotonic.side_effect = lambda: now[0]
                clock.sleep.side_effect = advance
                connection = socket_factory.return_value.__enter__.return_value
                connection.connect.side_effect = FileNotFoundError()
                codex_hook.deliver({}, Path("missing.sock"), event)
                self.assertEqual(now[0], 1.0 if event in codex_hook.TERMINAL_HOOKS else 0.0)
                self.assertEqual(socket_factory.call_count, clock.sleep.call_count + 1)
                if event not in codex_hook.TERMINAL_HOOKS:
                    clock.sleep.assert_not_called()

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
            with closing(sqlite3.connect(store.path)) as db, db:
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
