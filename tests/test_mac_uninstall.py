import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from macos.install import ROOT
from macos import uninstall as mac_uninstall
from macos.uninstall import cleaned_hooks


class HookRemovalTests(unittest.TestCase):
    def test_removes_only_paceman_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "hooks.json"
            paceman = f"/opt/homebrew/bin/python3 '{ROOT / 'lib/macos/codex_hook.py'}'"
            other = "/bin/echo still-here"
            original = {"custom": "keep", "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": paceman},
                                    {"type": "command", "command": other}]}],
                "SessionEnd": [{"hooks": [{"type": "command", "command": paceman}]}]}}
            path.write_text(json.dumps(original))
            result = cleaned_hooks(path)
            self.assertEqual(result["custom"], "keep")
            self.assertEqual(result["hooks"]["Stop"],
                             [{"hooks": [{"type": "command", "command": other}]}])
            self.assertEqual(result["hooks"]["SessionEnd"], [])
            self.assertEqual(json.loads(path.read_text()), original)

    def test_uninstall_removes_only_paceman_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "Paceman data"
            app = base / "Paceman.app"
            plist = base / "source.plist"
            hooks_path = base / "hooks.json"
            (root / "lib/macos").mkdir(parents=True)
            (root / "private").mkdir()
            (root / "private/apns-key.p8").write_text("test fixture")
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.paceman.macos"}))
            login_command = app / "Contents/MacOS/Paceman"
            login_command.parent.mkdir()
            login_command.touch()
            plist.write_bytes(plistlib.dumps({"Label": mac_uninstall.LABEL}))
            hooks_path.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [
                {"type": "command", "command": f"python3 '{root / 'lib/macos/codex_hook.py'}'"},
                {"type": "command", "command": "/bin/echo keep"}]}]}}))
            with patch.object(mac_uninstall, "ROOT", root), patch.object(mac_uninstall, "APP", app), \
                 patch.object(mac_uninstall, "PLIST", plist), patch.object(mac_uninstall, "HOOKS", hooks_path), \
                 patch.object(mac_uninstall, "PUSH_PLIST", base / "missing-push.plist"), \
                 patch.object(mac_uninstall.subprocess, "run") as command:
                result = mac_uninstall.uninstall()
            self.assertIn("Removed Paceman", result)
            self.assertFalse(root.exists())
            self.assertFalse(app.exists())
            self.assertFalse(plist.exists())
            self.assertEqual(json.loads(hooks_path.read_text())["hooks"]["Stop"],
                             [{"hooks": [{"type": "command", "command": "/bin/echo keep"}]}])
            self.assertEqual(command.call_args_list[0].args[0],
                             [str(login_command), "--unregister-login"])
            self.assertEqual(len(command.call_args_list), 2)


if __name__ == "__main__":
    unittest.main()
