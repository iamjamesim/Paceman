import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from omarchy import install
from omarchy.agents import apply, prepare
from service import network, push
from service.hub import Store
from tests.identity import device


class OmarchyUninstallTests(unittest.TestCase):
    def setUp(self):
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        self.home = Path(temporary).resolve() / "home"
        self.config = self.home / "custom-config"
        self.state = self.home / "custom-state/paceman"
        self.app = self.home / ".local/lib/paceman"
        self.ctl = self.home / ".local/bin/pacemanctl"
        self.plugin = self.config / "omarchy/plugins" / install.PLUGIN
        self.units = [self.config / "systemd/user" / name
                      for name in (install.SERVICE, install.PUSH_SERVICE)]
        self.store = Store(self.state / "hub.sqlite3")
        self.source_id = self.store.metadata("source_id")
        invitation = self.store.invite("https://test.ts.net")
        self.client = self.store.redeem(invitation["invitation"], device=device())
        token = {"deviceToken": "ab" * 32, "environment": "development"}
        self.store.push_device(self.client["credential"], token)
        self.store.watch_push_device(self.client["credential"], token)
        self.private = self.state / "private"
        self.private.mkdir()
        self.credential = "a" * 43
        (self.private / "apns.json").write_text(json.dumps({
            "relayURL": "https://relay.example", "sourceID": self.source_id,
            "credential": self.credential}))
        (self.state / "diagnostics.log").write_text("old activity")
        self.app.mkdir(parents=True)
        self.ctl.parent.mkdir(parents=True)
        self.ctl.touch()
        self.plugin.mkdir(parents=True)
        for unit in self.units:
            unit.parent.mkdir(parents=True, exist_ok=True)
            unit.touch()
        self.other_plugin = self.config / "omarchy/plugins/other/config.json"
        self.other_plugin.parent.mkdir()
        self.other_plugin.write_text("keep")
        self.custom_claude = self.home / "custom-claude"
        self.custom_claude.mkdir()
        self.claude_settings = self.custom_claude / "settings.json"
        self.original = {"permissions": {"allow": ["Read"]}, "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "other-hook"}]}]}}
        self.claude_settings.write_text(json.dumps(self.original))
        self.enterContext(patch.object(Path, "home", return_value=self.home))
        self.enterContext(patch.dict(os.environ, {
            "XDG_CONFIG_HOME": str(self.config),
            "XDG_STATE_HOME": str(self.state.parent),
            "CLAUDE_CONFIG_DIR": str(self.custom_claude)}))
        apply(prepare(self.state, self.app, ["codex", "claude"], home=self.home))
        # Uninstall must use the saved Claude profile, not the current environment.
        os.environ["CLAUDE_CONFIG_DIR"] = str(self.home / "different-claude")
        self.enterContext(patch.object(sys, "argv", ["install.py", "uninstall"]))
        self.commands = []
        self.running = set()

        def run(*args, **_):
            self.commands.append(args)
            output = ""
            if "--property=ActiveState" in args:
                output = "active\n" if args[3] in self.running else "inactive\n"
            return subprocess.CompletedProcess(args, 0, output, "")

        self.enterContext(patch.object(install, "run", side_effect=run))
        self.route = self.enterContext(patch.object(network, "remove_owned_route", return_value=False))
        response = Mock(status=200)
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        self.opener = Mock()

        def open_request(request, timeout):
            self.assertTrue((self.private / "apns.json").exists())
            self.assertEqual(timeout, 5)
            for service in (install.SERVICE, install.PUSH_SERVICE):
                self.assertIn(("/usr/bin/systemctl", "--user", "show", service,
                               "--property=ActiveState", "--value"), self.commands)
            return response

        self.opener.open.side_effect = open_request
        self.enterContext(patch.object(push, "build_opener", return_value=self.opener))

    def uninstall(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            install.main()
        return output.getvalue()

    def test_uninstall_wipes_pairings_and_tokens_and_reinstall_starts_fresh(self):
        output = self.uninstall()
        request = self.opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://relay.example/v2/sources")
        self.assertEqual(request.get_method(), "DELETE")
        self.assertEqual(request.get_header("Authorization"), "Bearer " + self.credential)
        self.assertEqual(json.loads(request.data), {"sourceID": self.source_id})
        self.assertNotIn(self.credential, output)
        for path in (self.state, self.app, self.ctl, self.plugin, *self.units):
            self.assertFalse(path.exists(), str(path))
        self.assertEqual(self.other_plugin.read_text(), "keep")
        self.assertEqual(json.loads(self.claude_settings.read_text())["permissions"], self.original["permissions"])
        self.assertEqual(json.loads(self.claude_settings.read_text())["hooks"]["Stop"], self.original["hooks"]["Stop"])
        self.assertTrue(all(not hooks for hooks in
                            json.loads((self.home / ".codex/hooks.json").read_text())["hooks"].values()))
        fresh = Store(self.state / "hub.sqlite3")
        self.assertNotEqual(fresh.metadata("source_id"), self.source_id)
        self.assertFalse(fresh.authorized(self.client["credential"]))
        with fresh.connect() as db:
            for table in ("clients", "client_devices", "push_devices", "watch_push_devices",
                          "live_activities", "live_activity_starts", "relay_revocations"):
                self.assertEqual(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0], 0)
        self.assertFalse((self.state / "private/apns.json").exists())

    def test_remote_cleanup_failure_does_not_keep_local_credentials(self):
        self.opener.open.side_effect = OSError("offline")
        (self.state / "tailscale-route.json").write_text("owned route")
        output = self.uninstall()
        self.assertFalse(self.state.exists())
        self.assertIn("Relay revocation could not be confirmed for source " + self.source_id, output)
        self.assertIn("route could not be removed", output)
        self.assertNotIn(self.credential, output)
        self.route.assert_called_once_with(self.state)

    def test_direct_apns_keys_are_removed_without_a_relay_request(self):
        (self.private / "apns.json").write_text(json.dumps({"keyPath": "apns-key.p8"}))
        (self.private / "apns-key.p8").write_text("private test key")
        self.uninstall()
        self.assertFalse(self.state.exists())
        self.opener.open.assert_not_called()

    def test_running_service_prevents_discarding_state(self):
        self.running.add(install.PUSH_SERVICE)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            self.uninstall()
        self.assertEqual(error.exception.code, 1)
        self.assertTrue((self.state / "hub.sqlite3").exists())
        self.assertTrue((self.private / "apns.json").exists())
        self.assertTrue(self.app.exists())
        self.opener.open.assert_not_called()

    def test_symlink_state_is_rejected_without_deleting_its_target(self):
        external = self.home / "external-state"
        self.state.rename(external)
        self.state.symlink_to(external, target_is_directory=True)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            self.uninstall()
        self.assertEqual(error.exception.code, 1)
        self.assertTrue((external / "hub.sqlite3").exists())
        self.assertEqual(self.commands, [])

    def test_repeated_uninstall_succeeds(self):
        self.uninstall()
        self.uninstall()
        self.assertFalse(self.state.exists())
        self.assertEqual(self.opener.open.call_count, 1)


if __name__ == "__main__":
    unittest.main()
