import json
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import macos.install as installer
from macos.install import PYTHON, install_hooks
from macos.codex_hook import EVENTS, QUESTION_MATCHER
from macos.control import missing_hooks
import macos.control as control
from service.hub import Store


class MacInstallTests(unittest.TestCase):
    def test_runtime_python_is_outside_checkout(self):
        self.assertFalse(Path(PYTHON).is_relative_to(Path(__file__).resolve().parent.parent))

    def test_prebuilt_install_uses_its_bundled_runtime_without_building(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "download/Paceman.app"
            library = source / "Contents/Resources/lib"
            (library / "macos").mkdir(parents=True)
            (library / "macos/install.py").touch()
            bundled = source / "Contents/Resources/python/bin/python3"
            bundled.parent.mkdir(parents=True)
            bundled.touch()
            (source / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": installer.BUNDLE_ID}))
            installed = base / "Applications/Paceman.app"
            root = base / "data"

            def finish(staged, **kwargs):
                self.assertTrue((staged / "Contents/Resources/python/bin/python3").is_file())
                self.assertEqual(installer.PYTHON,
                                 str(installed / "Contents/Resources/python/bin/python3"))
                self.assertFalse(kwargs["open_menu"])
                return True

            with patch.multiple(installer, ROOT=root, APP=installed, REPO=library,
                                LOGIN_ATTENTION=root / "login-setup-incomplete",
                                PYTHON=sys.executable), \
                 patch.object(installer, "build_app", side_effect=AssertionError("Xcode used")), \
                 patch.object(installer, "_finish_install", side_effect=finish):
                self.assertTrue(installer.install(prebuilt_app=source))

    def test_hook_install_preserves_existing_rules_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".codex/hooks.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo existing"}]}]},
                                        "customSetting": True}))
            added = install_hooks(path)
            first = json.loads(path.read_text())
            first_mtime = path.stat().st_mtime_ns
            repeated = install_hooks(path)
            second = json.loads(path.read_text())
            self.assertEqual(set(added), set(EVENTS))
            self.assertEqual(repeated, [])
            self.assertEqual(path.stat().st_mtime_ns, first_mtime)
            self.assertEqual(first, second)
            self.assertTrue(second["customSetting"])
            self.assertEqual(len(second["hooks"]["Stop"]), 2)
            self.assertEqual(second["hooks"]["Stop"][0]["hooks"][0]["command"], "echo existing")
            self.assertEqual(len(second["hooks"]), 8)
            self.assertEqual(second["hooks"]["PreToolUse"][0]["matcher"], QUESTION_MATCHER)

    def test_hook_upgrade_replaces_old_interpreter_without_adding_a_second_row(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "hooks.json"
            script = installer.ROOT / "lib/macos/codex_hook.py"
            old_command = f"/old/python3 {shlex.quote(str(script))}"
            path.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [
                {"type": "command", "command": old_command, "timeout": 3}]}]}}))
            changed = install_hooks(path)
            stop = json.loads(path.read_text())["hooks"]["Stop"]
            self.assertIn("Stop", changed)
            self.assertEqual(len(stop), 1)
            self.assertEqual(stop[0]["hooks"][0]["command"],
                             f"{shlex.quote(PYTHON)} -B {shlex.quote(str(script))}")

    def test_question_hook_upgrade_preserves_other_handlers_in_shared_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "hooks.json"
            script = installer.ROOT / "lib/macos/codex_hook.py"
            old_command = f"/old/python3 {shlex.quote(str(script))}"
            other = {"type": "command", "command": "echo other"}
            path.write_text(json.dumps({"hooks": {"PreToolUse": [{"hooks": [
                other, {"type": "command", "command": old_command, "timeout": 3}
            ]}]}}))

            self.assertIn("PreToolUse", install_hooks(path))
            groups = json.loads(path.read_text())["hooks"]["PreToolUse"]
            self.assertEqual(groups[0]["hooks"], [other])
            self.assertNotIn("matcher", groups[0])
            self.assertEqual(groups[1]["matcher"], QUESTION_MATCHER)
            self.assertEqual(groups[1]["hooks"][0]["command"],
                             f"{shlex.quote(PYTHON)} -B {shlex.quote(str(script))}")
            self.assertEqual(install_hooks(path), [])

    def test_missing_hooks_distinguishes_partial_and_complete_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "hooks.json"
            script = root / "codex_hook.py"
            script.touch()
            self.assertEqual(set(missing_hooks(config, script)), set(EVENTS))
            command = f"{shlex.quote(sys.executable)} {shlex.quote(str(script))}"
            config.write_text(json.dumps({"hooks": {
                event: [{**({"matcher": QUESTION_MATCHER} if event == "PreToolUse" else {}),
                         "hooks": [{"type": "command", "command": command}]}]
                for event in EVENTS if event != "Stop"
            }}))
            self.assertEqual(missing_hooks(config, script), ["Stop"])
            document = json.loads(config.read_text())
            document["hooks"]["Stop"] = [{"hooks": [{"type": "command", "command": command}]}]
            config.write_text(json.dumps(document))
            self.assertEqual(missing_hooks(config, script), [])

    def test_status_exposes_installed_hook_command_for_review(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "Paceman"
            root.mkdir()
            plist = Path(temporary) / "source.plist"
            python = Path(temporary) / "Paceman App/python3"
            plist.write_bytes(plistlib.dumps({"ProgramArguments": ["/app/background", str(python), str(root)]}))
            with patch.multiple(control, ROOT=root, PLIST=plist), \
                 patch.object(control, "missing_hooks", return_value=[]):
                result = control.status()
            self.assertEqual(result["hookCommand"],
                             f"{shlex.quote(str(python))} -B "
                             f"{shlex.quote(str(root / 'lib/macos/codex_hook.py'))}")

    def test_failed_service_start_restores_previous_install(self):
        self._exercise_replacement(fail_start=True)

    def test_failed_hook_commit_restores_previous_install(self):
        self._exercise_replacement(fail_hooks=True)

    def test_successful_service_start_replaces_install(self):
        self._exercise_replacement()

    def test_normal_install_prepares_relay_before_first_pairing(self):
        self._exercise_replacement(relay_url="https://relay.paceman.ai")

    def test_upgrade_preserves_existing_push_configuration(self):
        self._exercise_replacement(relay_url="https://relay.paceman.ai", existing_push=True)

    def test_failed_push_setup_reports_partial_install(self):
        self._exercise_replacement(relay_url="https://relay.paceman.ai", fail_push=True)

    def _exercise_replacement(self, fail_start: bool = False, fail_hooks: bool = False,
                              relay_url: str | None = None, existing_push: bool = False,
                              fail_push: bool = False):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            root = home / "Library/Application Support/Paceman"
            app = home / "Applications/Paceman.app"
            plist = home / "Library/LaunchAgents/ai.paceman.source.plist"
            push_plist = home / "Library/LaunchAgents/ai.paceman.push.plist"
            hooks = home / ".codex/hooks.json"
            repo = Path(temporary) / "repo"
            staging = root / ".install-test"
            staged_app = staging / "Paceman.app"
            for folder in ("service", "macos"):
                (root / "lib" / folder).mkdir(parents=True)
                (root / "lib" / folder / "version").write_text("old")
                (repo / folder).mkdir(parents=True)
                (repo / folder / "version").write_text("new")
            (root / "lib/desktop").mkdir()
            (root / "lib/desktop/version").write_text("legacy")
            (repo / "macos/launch_control.py").write_text("#!/usr/bin/python3 -I\nnew")
            (root / "bin").mkdir()
            (root / "bin/pacemanctl").write_text("old")
            (root / "menu-login-configured").write_text("registered\n")
            app.mkdir(parents=True)
            (app / "version").write_text("old")
            staged_app.mkdir(parents=True)
            (staged_app / "version").write_text("new")
            plist.parent.mkdir(parents=True)
            old_plist = plistlib.dumps({"Label": installer.LABEL, "Old": True})
            plist.write_bytes(old_plist)
            push_plist.write_bytes(plistlib.dumps({"Label": installer.PUSH_LABEL}))
            hooks.parent.mkdir(parents=True)
            hooks.write_text('{"hooks":{},"existing":true}\n')
            old_hooks = hooks.read_bytes()
            push_config = root / "private/apns.json"
            preserved_push = None
            if existing_push:
                push_config.parent.mkdir()
                source_id = Store(root / "data/hub.sqlite3").metadata("source_id")
                preserved_push = json.dumps({"relayURL": "https://custom.example",
                                             "sourceID": source_id, "credential": "x" * 43}) + "\n"
                push_config.write_text(preserved_push)
                (root / "push-venv/bin").mkdir(parents=True)
                (root / "push-venv/bin/python3").touch()
            bootstraps = []
            push_calls = []

            def configure_push(*, relay_url):
                push_calls.append(relay_url)
                if fail_push:
                    raise OSError("push dependencies unavailable")
                push_config.parent.mkdir(exist_ok=True)
                push_config.write_text(json.dumps({"relayURL": relay_url}))

            def command(args, **kwargs):
                if args[:2] == ["/bin/launchctl", "bootstrap"]:
                    bootstraps.append(args)
                    if fail_start and len(bootstraps) == 1:
                        raise subprocess.CalledProcessError(5, args, "new service failed")
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            original_replace = Path.replace

            def replace_path(path, target):
                if fail_hooks and path == staging / "hooks.json" and target == hooks:
                    raise OSError("hook replacement failed")
                return original_replace(path, target)

            with patch.multiple(installer, ROOT=root, APP=app, PLIST=plist, PUSH_PLIST=push_plist,
                                LOGIN_ATTENTION=root / "login-setup-incomplete",
                                REPO=repo, PYTHON=sys.executable), \
                 patch.object(Path, "home", return_value=home), \
                 patch.object(Path, "replace", replace_path), \
                 patch.object(installer.subprocess, "run", side_effect=command), \
                 patch("macos.install_push.install", side_effect=configure_push), \
                 patch("builtins.print"):
                if fail_start:
                    with self.assertRaises(subprocess.CalledProcessError):
                        installer._finish_install(staged_app, relay_url=relay_url)
                elif fail_hooks:
                    with self.assertRaises(OSError):
                        installer._finish_install(staged_app, relay_url=relay_url)
                else:
                    ready = installer._finish_install(staged_app, relay_url=relay_url)
                    self.assertEqual(ready, not fail_push)

            failed = fail_start or fail_hooks
            expected = "old" if failed else "new"
            for folder in ("service", "macos"):
                self.assertEqual((root / "lib" / folder / "version").read_text(), expected)
            self.assertEqual((root / "lib/desktop").exists(), failed)
            self.assertFalse((root / "lib/omarchy").exists())
            self.assertEqual((app / "version").read_text(), expected)
            self.assertEqual((root / "bin/pacemanctl").read_text(), "old" if failed else f"#!{sys.executable} -IB\nnew")
            if failed:
                self.assertEqual(plist.read_bytes(), old_plist)
                self.assertEqual(hooks.read_bytes(), old_hooks)
            else:
                self.assertEqual(plistlib.loads(plist.read_bytes())["ProgramArguments"][0],
                                 str(app / "Contents/MacOS/PacemanBackground"))
                self.assertEqual(len(json.loads(hooks.read_text())["hooks"]), 8)
            self.assertEqual(push_plist.exists(), failed)
            self.assertEqual((root / "notification-setup-incomplete").exists(),
                             fail_push and not failed)
            self.assertEqual(len(bootstraps), 3 if failed else 1)
            if relay_url and not failed:
                self.assertEqual(push_calls, [] if existing_push else [relay_url])
                self.assertEqual(push_config.exists(), not fail_push or existing_push)
                if existing_push:
                    self.assertEqual(push_config.read_text(), preserved_push)


if __name__ == "__main__":
    unittest.main()
