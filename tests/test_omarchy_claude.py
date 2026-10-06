import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from service.claude_hooks import message_for
from service.hub import Store
from service.omarchy import OmarchySource
from service.processes import AgentProcesses, ProcessIdentity
from service.push import live_notification
from omarchy import agents


class ClaudeSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store(self.root / "hub.sqlite3")
        self.enabled = ["codex", "claude"]
        self.processes = Mock(spec=AgentProcesses)
        self.processes.identify.side_effect = lambda pid, provider="codex": ProcessIdentity(
            100 if provider == "codex" else 200, "1", "boot") if pid else None
        self.processes.is_alive.return_value = True
        self.source = OmarchySource(self.store, socket_path=self.root / "agent.sock",
            state_dir=self.root, processes=self.processes, providers=self.enabled,
            settings_reader=lambda: self.enabled)
        self.source.__enter__()
        self.addCleanup(lambda: self.source.__exit__(None, None, None))

    def claude(self, hook, turn="one", **extra):
        command = message_for(dict(hook_event_name=hook, session_id="session",
                                   prompt_id=turn, **extra))
        self.assertIsNotNone(command)
        self.source.receive(command, peer_pid=2)
        return self.store.snapshot()

    def codex(self, event="working", turn="one"):
        self.source.receive(dict(command="agent-event", source="codex", session="session",
            turn=turn, event=event), peer_pid=1)
        return self.store.snapshot()

    def test_providers_coexist_and_one_can_be_disabled_without_clearing_other(self):
        self.codex()
        self.claude("UserPromptSubmit")
        before = self.claude("StopFailure")
        self.assertEqual(before["state"], "failed")
        self.assertEqual({s["provider"] for s in before["sessions"]}, {"codex", "claude"})
        self.enabled = ["codex"]
        self.source.tick(force=True)
        value = self.store.snapshot()
        self.assertEqual(value["state"], "working")
        self.assertEqual([s["provider"] for s in value["sessions"]], ["codex"])
        self.claude("UserPromptSubmit", turn="two")
        self.assertEqual(self.store.snapshot()["sessions"], value["sessions"])
        self.enabled = ["claude"]
        self.source.tick(force=True)
        self.claude("UserPromptSubmit", turn="two")
        self.assertEqual([s["provider"] for s in self.store.snapshot()["sessions"]], ["claude"])

    def test_attention_survives_unrelated_tool_results_and_source_restart(self):
        self.claude("UserPromptSubmit")
        self.claude("PreToolUse", tool_name="AskUserQuestion", tool_use_id="question")
        self.claude("PreToolUse", tool_name="Bash", tool_use_id="parallel")
        self.claude("PostToolUse", tool_name="Bash", tool_use_id="parallel")
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM omarchy_claude").fetchone()
            lifecycle = json.loads(row["lifecycle"])
            lifecycle["waits"] = {scope: self.source.monotonic() - 1 for scope in lifecycle["waits"]}
            db.execute("UPDATE omarchy_claude SET lifecycle=?", (json.dumps(lifecycle),))
        self.source.__exit__(None, None, None)
        self.source.__enter__()
        self.assertEqual(self.store.snapshot()["state"], "needs_input")
        self.claude("PostToolUse", tool_name="AskUserQuestion", tool_use_id="question")
        self.assertEqual(self.store.snapshot()["state"], "working")
        self.claude("Stop")
        self.assertEqual(self.store.snapshot()["state"], "finished")

    def test_old_prompt_callbacks_and_closed_session_cannot_reopen(self):
        self.claude("UserPromptSubmit")
        current = self.claude("UserPromptSubmit", turn="two")
        self.claude("Stop", turn="one")
        self.assertEqual(self.store.snapshot()["sessions"], current["sessions"])
        self.claude("SessionEnd", turn="")
        self.assertEqual(self.store.snapshot()["sessions"], [])
        self.claude("PreToolUse", turn="two", tool_name="Bash", tool_use_id="late")
        self.assertEqual(self.store.snapshot()["sessions"], [])
        self.claude("UserPromptSubmit", turn="three")
        self.assertEqual(self.store.snapshot()["state"], "working")

    def test_stop_continuation_requires_fresh_tool_start(self):
        self.claude("UserPromptSubmit")
        self.claude("Stop")
        self.claude("PostToolUse", tool_name="Bash", tool_use_id="late")
        self.assertEqual(self.store.snapshot()["state"], "finished")
        self.claude("PreToolUse", tool_name="Bash", tool_use_id="new")
        self.assertEqual(self.store.snapshot()["state"], "working")

    def test_process_exit_removes_claude_only_and_payload_does_not_include_hook_context(self):
        self.codex()
        self.claude("UserPromptSubmit", prompt="PRIVATE", cwd="/secret/workspace")
        public = json.dumps(self.store.snapshot())
        self.assertNotIn("PRIVATE", public)
        self.assertNotIn("workspace", public)
        self.processes.is_alive.side_effect = lambda identity: identity.pid != 200
        self.source.tick(force=True)
        self.assertEqual([s["provider"] for s in self.store.snapshot()["sessions"]], ["codex"])
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM omarchy_claude").fetchone()[0], 0)

    def test_no_peer_or_wrong_provider_process_is_ignored(self):
        message = message_for(dict(hook_event_name="UserPromptSubmit", session_id="one", prompt_id="one"))
        self.assertFalse(self.source.receive(message))
        self.processes.identify.return_value = None
        self.processes.identify.side_effect = None
        self.assertFalse(self.source.receive(message, peer_pid=2))
        self.assertEqual(self.store.snapshot()["sessions"], [])


    def test_remote_links_update_and_clear_without_new_activity(self):
        with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_first"}):
            first = self.claude("UserPromptSubmit")
        self.assertEqual(first["sessions"][0]["remoteSessionID"], "session_first")
        self.assertNotEqual(first["sessions"][0]["id"], "session")
        with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_second"}):
            updated = self.claude("PreToolUse", tool_name="Read", tool_use_id="r")
        self.assertEqual(updated["sessions"][0]["remoteSessionID"], "session_second")
        self.assertGreater(updated["revision"], first["revision"])
        self.assertEqual(updated["eventID"], first["eventID"])
        self.assertEqual(updated["changedAt"], first["changedAt"])
        with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": ""}):
            disconnected = self.claude("PostToolUse", tool_name="Read", tool_use_id="r")
        self.assertNotIn("remoteSessionID", disconnected["sessions"][0])
        self.assertEqual(disconnected["eventID"], first["eventID"])

    def test_session_start_updates_link_without_resetting_activity(self):
        with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_start"}):
            first = self.claude("SessionStart", turn="")
            self.assertEqual(first["sessions"][0]["remoteSessionID"], "session_start")
            working = self.claude("UserPromptSubmit")
        with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_resumed"}):
            resumed = self.claude("SessionStart", turn="")
        self.assertEqual(resumed["state"], "working")
        self.assertEqual(resumed["sessions"][0]["remoteSessionID"], "session_resumed")
        self.assertEqual(resumed["eventID"], working["eventID"])
        with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": ""}):
            local = self.claude("SessionStart", turn="")
        self.assertNotIn("remoteSessionID", local["sessions"][0])
        self.assertEqual(local["state"], "working")
        self.assertEqual(local["eventID"], working["eventID"])

    def test_remote_links_survive_restart_ignore_stale_events_and_clear_on_end(self):
        with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_current"}):
            current = self.claude("UserPromptSubmit", turn="new")
        with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_stale"}):
            self.claude("Stop", turn="old")
        self.assertEqual(self.store.snapshot()["sessions"], current["sessions"])
        self.source.__exit__(None, None, None)
        self.source.__enter__()
        restarted = self.store.snapshot()
        self.assertEqual(restarted["sessions"][0]["remoteSessionID"], "session_current")
        self.assertEqual(restarted["eventID"], current["eventID"])
        content = live_notification(restarted, time.time())[0]["aps"]["content-state"]
        self.assertNotIn("session_current", json.dumps(content))
        self.claude("SessionEnd", turn="new")
        self.assertEqual(self.store.snapshot()["sessions"], [])
        with self.store.connect() as db:
            lifecycle = json.loads(db.execute("SELECT lifecycle FROM omarchy_claude").fetchone()[0])
        self.assertIsNone(lifecycle["remote_session_id"])

    def test_remote_links_clear_when_provider_disabled_or_owner_exits(self):
        for clear in ("disable", "exit"):
            with self.subTest(clear=clear):
                self.enabled = ["codex", "claude"]
                self.processes.is_alive.return_value = True
                self.source.tick(force=True)
                with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": "session_clear"}):
                    self.claude("UserPromptSubmit", turn=clear)
                if clear == "disable":
                    self.enabled = ["codex"]
                else:
                    self.processes.is_alive.return_value = False
                self.source.tick(force=True)
                self.assertEqual(self.store.snapshot()["sessions"], [])
                with self.store.connect() as db:
                    self.assertEqual(db.execute("SELECT COUNT(*) FROM omarchy_claude").fetchone()[0], 0)

    def test_distinct_owners_keep_their_own_remote_links(self):
        self.processes.identify.side_effect = lambda pid, provider="codex": ProcessIdentity(pid, "1", "boot")
        for pid, local_id, remote_id in ((2, "local-a", "session_a"), (3, "local-b", "session_b")):
            with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": remote_id}):
                command = message_for(dict(hook_event_name="UserPromptSubmit", session_id=local_id,
                                           prompt_id="one"))
            self.source.receive(command, peer_pid=pid)
        sessions = self.store.snapshot()["sessions"]
        self.assertEqual(len(sessions), 2)
        self.assertEqual({s["remoteSessionID"] for s in sessions}, {"session_a", "session_b"})

    def test_invalid_remote_ids_are_normalized_or_rejected(self):
        for remote_id in ("local-uuid", "session_x\n", "session_x/other", "session_x?prompt=secret", "session_", "session_" + "x" * 153):
            with self.subTest(remote_id=remote_id):
                with patch.dict(os.environ, {"CLAUDE_CODE_BRIDGE_SESSION_ID": remote_id}):
                    command = message_for(dict(hook_event_name="UserPromptSubmit", session_id="session", prompt_id="one"))
                self.assertIsNone(command["remoteSessionID"])
                command["remoteSessionID"] = remote_id
                with self.assertRaises(ValueError):
                    self.source.receive(command, peer_pid=2)
        self.assertEqual(self.store.snapshot()["sessions"], [])

    def test_isolated_omarchy_hook_subprocess_delivers_remote_metadata(self):
        self.source.__exit__(None, None, None)
        self.source.socket_path = self.root / "omarchy-watch.sock"
        self.source.__enter__()
        receive = self.source.receive
        # Mac lacks Linux peer credentials. Linux's real owner check is covered
        # in test_processes; this verifies the installed script and wire payload.
        with patch.object(self.source, "receive", side_effect=lambda command, peer_pid=None: receive(command, peer_pid=2)):
            result = subprocess.run([sys.executable, "-I", "omarchy/claude_hook.py"],
                input=json.dumps(dict(hook_event_name="UserPromptSubmit", session_id="private-session",
                    prompt_id="private-prompt", remoteSessionID="session_injected", cwd="/PRIVATE/PATH",
                    prompt="PRIVATE PROMPT", transcript_path="/PRIVATE/TRANSCRIPT", tool_input={"command": "PRIVATE COMMAND"})),
                env={**os.environ, "XDG_RUNTIME_DIR": str(self.root), "CLAUDE_CODE_BRIDGE_SESSION_ID": "session_socket"},
                capture_output=True, text=True, check=True, timeout=3)
        self.assertEqual((result.stdout, result.stderr), ("", ""))
        snapshot = self.store.snapshot()
        self.assertEqual(snapshot["sessions"][0]["remoteSessionID"], "session_socket")
        public = json.dumps(snapshot)
        for secret in ("PRIVATE", "private-session", "private-prompt", "session_injected"):
            self.assertNotIn(secret, public)


class AgentConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.root = self.home / "state"
        self.app = self.home / "app"
        self.environment = patch.dict("os.environ", {"CLAUDE_CONFIG_DIR": str(self.home / "custom-claude")})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_fresh_detection_preserves_saved_and_legacy_selections(self):
        for detected in ([], ['codex'], ['claude'], ['codex', 'claude']):
            with self.subTest(detected=detected), patch.object(agents, 'detected_providers', return_value=detected):
                self.assertEqual(agents.setup_providers(self.root, home=self.home), detected)
        self.root.mkdir()
        for saved in ([], ['codex'], ['claude'], ['codex', 'claude']):
            (self.root / 'agents.json').write_text(json.dumps({'providers': saved,
                'claudeConfigDir': str(self.home / 'custom-claude')}))
            with self.subTest(saved=saved), patch.object(agents, 'detected_providers', side_effect=AssertionError('Upgrade changed selection')):
                self.assertEqual(agents.setup_providers(self.root, home=self.home), saved)
        (self.root / 'agents.json').unlink()
        (self.root / 'hub.sqlite3').touch()
        with patch.object(agents, 'detected_providers', return_value=['claude']):
            self.assertEqual(agents.setup_providers(self.root, home=self.home), ['codex'])

    def test_installer_uses_detection_then_preserves_disables(self):
        import os
        import subprocess
        import time
        from omarchy import install
        def run(*args, **kwargs):
            return subprocess.CompletedProcess(args, 0, json.dumps({'running': True, 'startedAt': time.time()}), '')
        with patch.object(install.Path, 'home', return_value=self.home), \
                patch.dict(os.environ, {'XDG_STATE_HOME': str(self.home / 'state'), 'XDG_CONFIG_HOME': str(self.home / 'config')}), \
                patch.object(install, 'run', side_effect=run), patch.object(install.socket, 'socket'), \
                patch('service.network.ensure_private_route', return_value='https://test.ts.net'), \
                patch.object(agents, 'detected_providers', return_value=['claude']) as detect, \
                patch('sys.argv', ['install.py', 'install', '--no-bar', '--no-push-setup']), patch('builtins.print'):
            install.main()
            state = self.home / 'state/paceman'
            app = self.home / '.local/lib/paceman'
            self.assertEqual(agents.configured_providers(state), ['claude'])
            self.assertFalse((self.home / '.codex/hooks.json').exists())
            agents.configure(state, app, disable='claude', home=self.home)
            install.main()
            self.assertEqual(agents.configured_providers(state), [])
            self.assertEqual(detect.call_count, 1)

    def test_detection_is_symmetric_for_editor_only_installations(self):
        with patch.object(agents.shutil, 'which', return_value=None):
            for extension in ('openai.chatgpt-0.4.0', 'anthropic.claude-code-2.1.211'):
                (self.home / '.vscode/extensions' / extension).mkdir(parents=True)
            self.assertEqual(agents.detected_providers(self.root, home=self.home), ['codex', 'claude'])

    def prepare_hook_fixture(self):
        (self.app / "omarchy").mkdir(parents=True)
        for provider in agents.PROVIDERS:
            (self.app / f"omarchy/{provider}_hook.py").touch()
        agents.configure(self.root, self.app, enable="claude", home=self.home)
        return agents.hook_paths(self.root, home=self.home)

    def test_missing_hooks_repair_is_scoped_preserves_settings_and_requires_new_event(self):
        paths = self.prepare_hook_fixture()
        for provider in agents.PROVIDERS:
            with self.subTest(provider=provider):
                before = {p: path.read_bytes() for p, path in paths.items()}
                value = json.loads(paths[provider].read_text())
                value['env'] = {'USER_SETTING': 'keep'}
                value['hooks']['Stop'] = [{'hooks': [{'type': 'command', 'command': '/usr/bin/true'}]}]
                paths[provider].write_text(json.dumps(value))
                status = agents.hook_status(self.root, self.app, home=self.home)
                self.assertEqual(status[provider], 'missing')
                agents.configure(self.root, self.app, repair=provider, home=self.home)
                self.assertEqual(agents.hook_status(self.root, self.app, home=self.home)[provider], 'ready')
                repaired = json.loads(paths[provider].read_text())
                self.assertEqual(repaired['env'], value['env'])
                self.assertEqual(repaired['hooks']['Stop'][0], value['hooks']['Stop'][0])
                self.assertGreater(agents.configuration(self.root)['hookReviewAfter'][provider], 0)
                other = 'claude' if provider == 'codex' else 'codex'
                self.assertEqual(paths[other].read_bytes(), before[other])
                self.assertEqual(agents.configured_providers(self.root), ['codex', 'claude'])

    def test_disabled_malformed_and_missing_script_have_distinct_diagnosis(self):
        paths = self.prepare_hook_fixture()
        value = json.loads(paths['claude'].read_text())
        value['disableAllHooks'] = True
        paths['claude'].write_text(json.dumps(value))
        agents.configure(self.root, self.app, repair='claude', home=self.home)
        self.assertEqual(agents.hook_status(self.root, self.app, home=self.home),
                         {'codex': 'ready', 'claude': 'disabled'})
        self.assertTrue(json.loads(paths['claude'].read_text())['disableAllHooks'])
        paths['claude'].write_text('{')
        before = (self.root / 'agents.json').read_bytes()
        with self.assertRaises(ValueError):
            agents.configure(self.root, self.app, repair='claude', home=self.home)
        self.assertEqual((self.root / 'agents.json').read_bytes(), before)
        self.assertEqual(agents.hook_status(self.root, self.app, home=self.home),
                         {'codex': 'ready', 'claude': 'invalid'})
        (self.app / 'omarchy/claude_hook.py').unlink()
        self.assertEqual(agents.hook_status(self.root, self.app, home=self.home)['claude'], 'unavailable')

    def test_repair_does_not_enable_disabled_agents_or_touch_broken_other_provider(self):
        paths = self.prepare_hook_fixture()
        paths['codex'].write_text('{')
        paths['claude'].unlink()
        agents.configure(self.root, self.app, repair='claude', home=self.home)
        self.assertEqual(paths['codex'].read_text(), '{')
        self.assertEqual(agents.hook_status(self.root, self.app, home=self.home)['claude'], 'ready')
        paths['codex'].write_text('{}')
        agents.configure(self.root, self.app, disable='claude', home=self.home)
        with self.assertRaises(ValueError):
            agents.configure(self.root, self.app, repair='claude', home=self.home)
        self.assertEqual(agents.configured_providers(self.root), ['codex'])

    def test_scoped_or_async_owned_hooks_are_detected_and_restored(self):
        paths = self.prepare_hook_fixture()
        for provider in agents.PROVIDERS:
            value = json.loads(paths[provider].read_text())
            value['hooks']['Stop'][0]['matcher'] = 'restricted'
            value['hooks']['PreToolUse'][0]['hooks'][0]['async'] = True
            paths[provider].write_text(json.dumps(value))
            self.assertEqual(agents.hook_status(self.root, self.app, home=self.home)[provider], 'missing')
            agents.configure(self.root, self.app, repair=provider, home=self.home)
            self.assertEqual(agents.hook_status(self.root, self.app, home=self.home)[provider], 'ready')

    def test_opt_in_idempotence_disable_and_preservation_of_other_settings(self):
        path = self.home / "custom-claude/settings.json"
        path.parent.mkdir()
        unrelated = {"env": {"CUSTOM": "kept"}, "hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": "/usr/bin/true"}]}]}}
        path.write_text(json.dumps(unrelated))
        self.assertEqual(agents.configured_providers(self.root), ["codex"])
        agents.configure(self.root, self.app, enable="claude", home=self.home)
        before = path.read_bytes()
        configured = json.loads(before)
        self.assertEqual(configured["env"], unrelated["env"])
        self.assertEqual(configured["hooks"]["Stop"][0], unrelated["hooks"]["Stop"][0])
        self.assertEqual(set(configured["hooks"]), set(agents.CLAUDE_EVENTS))
        agents.configure(self.root, self.app, enable="claude", home=self.home)
        self.assertEqual(path.read_bytes(), before)
        agents.configure(self.root, self.app, disable="claude", home=self.home)
        after = json.loads(path.read_text())
        self.assertEqual(after["hooks"]["Stop"], unrelated["hooks"]["Stop"])
        self.assertEqual(after["env"], unrelated["env"])
        self.assertEqual(agents.configured_providers(self.root), ["codex"])

    def test_detection_does_not_mistake_our_own_settings_for_an_installed_agent(self):
        agents.configure(self.root, self.app, enable="claude", home=self.home)
        agents.configure(self.root, self.app, disable="claude", home=self.home)
        with patch.object(agents.shutil, "which", return_value=None):
            self.assertNotIn("claude", agents.detected_providers(self.root, home=self.home))
            extension = self.home / ".vscode/extensions/anthropic.claude-code-2.1.211"
            extension.mkdir(parents=True)
            self.assertIn("claude", agents.detected_providers(self.root, home=self.home))

    def test_bad_claude_config_does_not_change_codex_or_selection(self):
        agents.configure(self.root, self.app, enable="codex", home=self.home)
        codex = self.home / ".codex/hooks.json"
        before = codex.read_bytes()
        settings = self.home / "custom-claude/settings.json"
        settings.parent.mkdir(exist_ok=True)
        settings.write_text("{")
        with self.assertRaises(ValueError):
            agents.configure(self.root, self.app, enable="claude", home=self.home)
        self.assertEqual(codex.read_bytes(), before)
        self.assertEqual(agents.configured_providers(self.root), ["codex"])

    def test_partial_write_failure_restores_original_files(self):
        agents.configure(self.root, self.app, enable="claude", home=self.home)
        paths = agents.hook_paths(self.root, home=self.home)
        originals = {path: path.read_bytes() for path in paths.values()}
        originals[self.root / "agents.json"] = (self.root / "agents.json").read_bytes()
        real_write = agents.write
        failed = False
        def write(path, data, mode):
            nonlocal failed
            if path.name == "agents.json" and not failed:
                failed = True
                raise OSError("fixture write failure")
            real_write(path, data, mode)
        with patch.object(agents, "write", side_effect=write), self.assertRaises(OSError):
            agents.configure(self.root, self.app, disable="claude", home=self.home)
        for path, before in originals.items():
            self.assertEqual(path.read_bytes(), before)

    def test_symlink_settings_are_rejected_before_any_changes(self):
        path = self.home / "custom-claude/settings.json"
        path.parent.mkdir()
        path.symlink_to(self.home / "missing")
        with self.assertRaises(ValueError):
            agents.configure(self.root, self.app, enable="claude", home=self.home)
        self.assertFalse((self.root / "agents.json").exists())
