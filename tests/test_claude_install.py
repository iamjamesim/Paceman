import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from macos import install, control, uninstall, agents

class ClaudeInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp=self.enterContext(tempfile.TemporaryDirectory())
        self.home=Path(self.temp)/"home"
        self.root=self.home/"Library/Application Support/Paceman"
        (self.root/"lib/macos").mkdir(parents=True)
        (self.root/"lib/macos/claude_hook.py").touch()
        (self.root/"lib/macos/codex_hook.py").touch()
        self.enterContext(patch.object(Path,"home",return_value=self.home))
        self.enterContext(patch.dict(os.environ,{"CLAUDE_CONFIG_DIR":""}))
        self.enterContext(patch.multiple(install,ROOT=self.root,PYTHON=sys.executable))
        self.enterContext(patch.multiple(control,ROOT=self.root,PLIST=self.home/"source.plist"))
        self.enterContext(patch.object(uninstall,"ROOT",self.root))
    def test_claude_install_upgrade_and_removal_preserve_other_settings(self):
        path=agents.hook_path("claude",root=self.root)
        path.parent.mkdir(parents=True)
        original={"permissions":{"allow":["Read"]},"statusLine":{"type":"command","command":"my-status"},
                  "hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-hook"}]}]}}
        path.write_text(json.dumps(original))
        self.assertEqual(len(install.install_hooks(path,provider="claude")),12)
        saved=json.loads(path.read_text())
        self.assertEqual(install.install_hooks(path,provider="claude"),[])
        self.assertEqual(control.missing_hooks(provider="claude"),[])
        self.assertEqual(saved["statusLine"],original["statusLine"])
        cleaned=uninstall.cleaned_hooks(path,provider="claude")
        self.assertEqual(cleaned["permissions"],original["permissions"])
        self.assertEqual(cleaned["hooks"]["Stop"],original["hooks"]["Stop"])
        self.assertTrue(all(not value for key,value in cleaned["hooks"].items() if key != "Stop"))
    def test_shared_matchers_and_conditions_do_not_silently_filter_activity(self):
        path=agents.hook_path("claude",root=self.root);path.parent.mkdir(parents=True)
        script=self.root/"lib/macos/claude_hook.py"
        path.write_text(json.dumps({"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
            {"type":"command","command":"other"}, {"type":"command","command":f"{sys.executable} '{script}'","if":"Bash(ls)","async":True}]}]}}))
        install.install_hooks(path,provider="claude")
        groups=json.loads(path.read_text())["hooks"]["PreToolUse"]
        self.assertEqual(groups[0],{"matcher":"Bash","hooks":[{"type":"command","command":"other"}]})
        self.assertNotIn("matcher",groups[1]);self.assertNotIn("if",groups[1]["hooks"][0])
        self.assertNotIn("async",groups[1]["hooks"][0]);self.assertEqual(control.missing_hooks(provider="claude"),[])
    def test_disabled_hooks_remain_disabled_and_are_reported(self):
        path=agents.hook_path("claude",root=self.root);path.parent.mkdir(parents=True)
        path.write_text('{"disableAllHooks":true}')
        install.install_hooks(path,provider="claude")
        self.assertTrue(json.loads(path.read_text())["disableAllHooks"])
        self.assertEqual(len(control.missing_hooks(provider="claude")),12)
    def test_configure_and_deselect_roll_back_on_write_failure(self):
        codex=agents.hook_path("codex");codex.parent.mkdir(parents=True)
        codex.write_text('{"keep":true,"hooks":{}}')
        original=codex.read_bytes()
        with patch("macos.control.os.fdopen",side_effect=OSError("write failed")):
            with self.assertRaises(OSError):control.configure_agents(["claude"])
        self.assertEqual(codex.read_bytes(),original)
        self.assertFalse(agents.hook_path("claude").exists())
        self.assertFalse((self.root/"agents.json").exists())
        with patch.object(control,"launch"):
            control.configure_agents(["codex","claude"])
            control.configure_agents(["claude"])
        with patch.object(control,"launch") as launch:
            control.configure_agents(["codex"])
            launch.assert_not_called()
        with patch.object(control,"launch"):
            control.configure_agents(["claude"])
        self.assertEqual(agents.configured_providers(self.root),["claude"])
        self.assertTrue(all(not v for v in json.loads(codex.read_text())["hooks"].values()))
        self.assertEqual(control.missing_hooks(provider="claude"),[])
    def test_custom_claude_profile_survives_environment_free_update_and_removal(self):
        custom=self.home/"custom-claude"
        with patch.dict(os.environ,{"CLAUDE_CONFIG_DIR":str(custom)}), patch.object(control,"launch"):
            control.configure_agents(["claude"])
        self.assertEqual(agents.hook_path("claude",root=self.root),custom/"settings.json")
        self.assertEqual(control.missing_hooks(provider="claude"),[])
        self.assertIsNotNone(uninstall.cleaned_hooks(agents.hook_path("claude",root=self.root),provider="claude"))


    def test_repairing_existing_hooks_does_not_restart_source(self):
        (self.root/'agents.json').write_text(json.dumps({'providers':['codex','claude']}))
        with patch.object(control,'launch') as launch:
            control.configure_agents(['codex','claude'])
            launch.assert_not_called()

    def test_only_claude_can_be_turned_off_without_enabling_codex(self):
        with patch.object(control,'launch') as launch:
            control.configure_agents(['claude'])
            control.configure_agents([])
            launch.assert_not_called()
        self.assertEqual(agents.configured_providers(self.root),[])
        self.assertTrue(all(not groups for groups in json.loads(agents.hook_path('claude',root=self.root).read_text())['hooks'].values()))
