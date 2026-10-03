import http.client
import io
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from omarchy import install
from omarchy import install_push
from omarchy.control import read_status, set_sharing, pair_phone, remove_access
from service.network import RouteSetupError, private_endpoint
from tests.identity import device
from service.hub import Server, Store
from service.status import DesktopStatus


class DesktopStatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store(self.root / "hub.sqlite3")
        self.path = self.root / "runtime/status.json"
        self.status = DesktopStatus(self.path, self.store)

    def test_status_has_no_credentials_and_expires_after_crash(self):
        invitation = self.store.invite("https://test.example")
        client = self.store.redeem(invitation["invitation"], device=device())
        self.status.publish(force=True)
        value = read_status(self.path)
        self.assertTrue(value["running"])
        self.assertFalse(value["phoneRecent"])
        self.assertEqual(value["mode"], "synthetic")
        self.assertNotIn("mode", self.store.snapshot())
        self.assertEqual(value["pairedPhones"], 1)
        self.assertNotIn(client["credential"], self.path.read_text())
        self.assertEqual(value["clients"][0]["id"], client["clientID"])
        self.assertEqual(value["clients"][0]["name"], "Test iPhone")
        self.assertNotIn('"hash"', self.path.read_text())
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(read_status(self.path, now=value["updatedAt"] + 20)["running"])
        self.assertFalse(read_status(self.path, now=value["updatedAt"] - 1)["running"])
        self.status.publish(stopped=True, force=True)
        self.assertFalse(read_status(self.path)["running"])

    def test_only_successful_authenticated_snapshot_counts_as_phone_contact(self):
        server = Server(("127.0.0.1", 0), self.store, desktop_status=self.status)
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=.01), daemon=True)
        thread.start()
        try:
            def fetch(token=None):
                connection = http.client.HTTPConnection(*server.server_address, timeout=2)
                connection.request("GET", "/v1/snapshot", headers={} if token is None else {"Authorization": "Bearer " + token})
                response = connection.getresponse()
                result = response.status
                response.read()
                connection.close()
                return result
            self.assertEqual(fetch(), 401)
            self.assertEqual(self.status.phone_seen, 0)
            invitation = self.store.invite("https://test.example")
            client = self.store.redeem(invitation["invitation"], device=device())
            self.assertEqual(fetch(client["credential"]), 200)
            deadline = time.monotonic() + 2
            while not self.status.phone_seen and time.monotonic() < deadline:
                time.sleep(.01)
            self.status.publish(force=True)
            self.assertTrue(read_status(self.path)["phoneRecent"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_missing_or_malformed_status_is_unavailable(self):
        self.assertFalse(read_status(self.path)["running"])
        self.path.parent.mkdir()
        for body in ("{", "[]", '{"schema":1,"updatedAt":"bad"}'):
            self.path.write_text(body)
            self.assertFalse(read_status(self.path)["running"])

    def test_remove_access_works_while_paused_and_preserves_other_clients(self):
        first, second = [self.store.redeem(self.store.invite('https://test.example')['invitation'], device=device()) for _ in range(2)]
        self.store.push_device(first['credential'], {'deviceToken': 'ab' * 32, 'environment': 'development'})
        (self.root / 'sharing-paused').write_text('{}')
        with patch('omarchy.control.state_directory', return_value=self.root), patch('omarchy.control.status_path', return_value=self.root / 'absent'):
            status = remove_access(first['clientID'])
            self.assertFalse(status['sharingEnabled'])
            self.assertEqual([row['id'] for row in status['clients']], [second['clientID']])
            self.assertFalse(self.store.authorized(first['credential']))
            self.assertTrue(self.store.authorized(second['credential']))
            self.assertEqual(remove_access(first['clientID'])['clients'], status['clients'])
            with self.assertRaises(ValueError):
                remove_access('../all')

    @unittest.skipUnless(shutil.which("node"), "Node.js is needed for panel presentation tests")
    def test_panel_presentation(self):
        result = subprocess.run(["node", "--test", str(Path(__file__).with_name("test_panel_model.cjs"))],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_pairing_only_reuses_unambiguous_private_route(self):
        config = {"TCP": {"8443": {"HTTPS": True}}, "Web": {
            "test.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8765"}}}}}
        self.assertEqual(private_endpoint(config), "https://test.ts.net:8443")
        config["AllowFunnel"] = {"test.ts.net:8443": True}
        with self.assertRaises(ValueError):
            private_endpoint(config)
        for config in ({}, {"Web": {"wrong:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9999"}}}}}):
            with self.assertRaises(ValueError):
                private_endpoint(config)

    def test_sharing_choice_persists_and_rolls_back_on_service_failure(self):
        marker = self.root / "sharing-paused"
        with patch("omarchy.control.pause_path", return_value=marker), patch("omarchy.control.subprocess.run") as run:
            set_sharing(False)
            self.assertTrue(marker.exists())
            self.assertIn("disable", run.call_args.args[0])
            set_sharing(True)
            self.assertFalse(marker.exists())
            self.assertIn("enable", run.call_args.args[0])
            run.side_effect = subprocess.CalledProcessError(1, "systemctl")
            with self.assertRaises(subprocess.CalledProcessError):
                set_sharing(False)
            self.assertFalse(marker.exists())
            marker.write_text('{"paused":true}')
            with self.assertRaises(subprocess.CalledProcessError):
                set_sharing(True)
            self.assertTrue(marker.exists())

    def test_paused_status_survives_missing_runtime_file(self):
        marker = self.root / "sharing-paused"
        marker.write_text('{"paused":true}')
        client = self.store.redeem(self.store.invite("https://test.example")["invitation"], device=device())
        with patch("omarchy.control.state_directory", return_value=self.root), \
             patch("omarchy.control.status_path", return_value=self.root / "missing.json"):
            value = read_status()
            self.assertFalse(value["sharingEnabled"])
            self.assertFalse(value["running"])
            self.assertEqual(value["pairedPhones"], 1)
            self.assertNotIn(client["credential"], json.dumps(value))

    @unittest.skipUnless(Path("/usr/bin/qrencode").exists(), "qrencode is optional")
    def test_panel_pairing_returns_only_image_location_and_expiry(self):
        output = io.StringIO()
        with patch("omarchy.control.state_directory", return_value=self.root), \
             patch("omarchy.control.read_status", return_value={"running": True}), \
             patch("omarchy.control.ensure_private_route", return_value="https://test.ts.net:8443"), \
             redirect_stdout(output):
            pair_phone(json_output=True)
        value = json.loads(output.getvalue())
        self.assertEqual(set(value), {"qrPath", "expiresAt"})
        self.assertTrue(Path(value["qrPath"]).read_bytes().startswith(b"\x89PNG"))
        secret = json.loads((self.root / "invitation.json").read_text())["invitation"]
        self.assertNotIn(secret, output.getvalue())


class DesktopInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # macOS exposes /var as a symlink, which the installer rightly refuses.
        self.root = Path(self.temp.name).resolve()

    def test_installer_rejects_symlink_destinations(self):
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        link.symlink_to(target)
        with self.assertRaises(ValueError):
            install.write(link / "file", b"must not be written")
        self.assertFalse((target / "file").exists())

    def test_install_upgrade_uninstall_preserve_data_with_mocked_system_services(self):
        source = self.root / "source"
        for directory in ("omarchy", "service", "systemd"):
            shutil.copytree(install.ROOT / directory, source / directory,
                            ignore=shutil.ignore_patterns("__pycache__"))
        Store(source / ".runtime/hub.sqlite3")
        home = self.root / "home"
        hooks = home / ".codex/hooks.json"
        hooks.parent.mkdir(parents=True)
        unrelated = {"hooks": {"Stop": [{"hooks": [{"type": "command",
            "command": "/usr/bin/true", "timeout": 3}]}]}}
        hooks.write_text(json.dumps(unrelated))
        legacy = home / ".local/lib/paceman/desktop"
        legacy.mkdir(parents=True)
        (legacy / "old.py").write_text("# old installation\n")
        calls = []
        push_running = {"value": True}
        def fake_run(*args, **kwargs):
            calls.append(args)
            output = (json.dumps({"running": True, "startedAt": time.time()}) if args[-1] == "status"
                      else "active" if args[-2:] == ("is-active", "paceman-push.service") and push_running["value"]
                      else "inactive" if args[-2:] == ("is-active", "paceman-push.service") else "ok")
            return subprocess.CompletedProcess(args, 0, output, "")
        def fake_push_run(args, **kwargs):
            if args[1:3] == ["-m", "venv"]:
                python = Path(args[3]) / "bin/python3"
                python.parent.mkdir(parents=True)
                python.touch()
            return subprocess.CompletedProcess(args, 0)
        with patch.object(install, "ROOT", source), patch.object(install.Path, "home", return_value=home), \
             patch.object(install, "run", side_effect=fake_run), \
             patch.object(install_push.subprocess, "run", side_effect=fake_push_run), \
             patch("service.network.ensure_private_route", return_value="https://test.ts.net:8443"), \
             patch.dict(os.environ, {"XDG_STATE_HOME": str(home / ".local/state"), "XDG_CONFIG_HOME": str(home / ".config")}), \
             patch.object(install.socket, "socket"):
            with patch("sys.argv", ["install.py", "install"]):
                install.main()
            self.assertTrue((home / ".local/lib/paceman/omarchy/codex_hook.py").exists())
            self.assertTrue((home / ".local/lib/paceman/omarchy/CODEX_HOOK_UPSTREAM.md").exists())
            self.assertTrue((home / ".local/lib/paceman/omarchy/OMARCHY_WATCH_CODEX_LICENSE").exists())
            self.assertFalse(legacy.exists())
            self.assertEqual(hooks.stat().st_mode & 0o777, 0o600)
            installed_hooks = json.loads(hooks.read_text())["hooks"]
            self.assertEqual(set(installed_hooks), set(install.HOOK_EVENTS))
            self.assertEqual(installed_hooks["Stop"][0], unrelated["hooks"]["Stop"][0])
            for event in install.HOOK_EVENTS:
                self.assertTrue(any(install.owns_hook(item, home / ".local/lib/paceman")
                    for group in installed_hooks[event] for item in group["hooks"]))
            self.assertTrue((home / ".local/state/paceman/hub.sqlite3").exists())
            push_config = home / ".local/state/paceman/private/apns.json"
            self.assertEqual(json.loads(push_config.read_text())["relayURL"], "https://relay.paceman.ai")
            original_push_config = push_config.read_bytes()
            installed = Store(home / ".local/state/paceman/hub.sqlite3")
            client = installed.redeem(installed.invite("https://test.example")["invitation"], device=device())
            with patch("sys.argv", ["install.py", "install"]):
                install.main()
            self.assertEqual(push_config.read_bytes(), original_push_config)
            self.assertEqual(json.loads(hooks.read_text())["hooks"], installed_hooks)
            self.assertTrue(Store(installed.path).authorized(client["credential"]))
            unit = (home / ".config/systemd/user/paceman-source.service").read_text()
            self.assertNotIn(str(source), unit)
            self.assertNotIn("@APP@", unit)
            self.assertIn("--relay-config", unit)
            self.assertIn("Wants=paceman-push.service", unit)
            push_unit = (home / ".config/systemd/user/paceman-push.service").read_text()
            self.assertIn("PartOf=paceman-source.service", push_unit)
            self.assertIn("push-venv/bin/python3", push_unit)
            self.assertNotIn("@STATE@", push_unit)
            self.assertTrue((home / ".local/bin/pacemanctl").exists())
            with patch("service.network.ensure_private_route", side_effect=RouteSetupError("Enable Tailscale HTTPS")), \
                 patch("sys.argv", ["install.py", "install"]):
                with self.assertRaises(SystemExit) as incomplete:
                    install.main()
            self.assertEqual(incomplete.exception.code, 2)
            push_running["value"] = False
            with patch.object(install.time, "sleep"), patch("sys.argv", ["install.py", "install"]):
                with self.assertRaises(SystemExit) as incomplete:
                    install.main()
            self.assertEqual(incomplete.exception.code, 2)
            push_running["value"] = True
            (home / ".local/state/paceman/sharing-paused").write_text('{"paused":true}')
            calls.clear()
            with patch("sys.argv", ["install.py", "install"]):
                install.main()
            self.assertNotIn(("/usr/bin/systemctl", "--user", "enable", "--now", "paceman-source.service"), calls)
            self.assertIn(("/usr/bin/systemctl", "--user", "disable", "--now", "paceman-source.service"), calls)
            with patch("sys.argv", ["install.py", "uninstall"]):
                install.main()
            self.assertIn(("/usr/bin/systemctl", "--user", "disable", "--now", "paceman-push.service"), calls)
            self.assertTrue(Store(installed.path).authorized(client["credential"]))
            self.assertFalse((home / ".local/bin/pacemanctl").exists())
            self.assertFalse((home / ".local/lib/paceman").exists())
            self.assertFalse((home / ".config/systemd/user/paceman-push.service").exists())
            self.assertEqual(json.loads(hooks.read_text()), {"hooks": {
                **{event: [] for event in install.HOOK_EVENTS if event != "Stop"},
                "Stop": unrelated["hooks"]["Stop"]}})

    def test_hook_config_is_validated_before_install_changes_services(self):
        hooks = self.root / "hooks.json"
        hooks.write_text('{')
        with self.assertRaises(json.JSONDecodeError):
            install.hook_document(hooks, self.root / "app")
        hooks.unlink()
        hooks.symlink_to(self.root / "missing")
        with self.assertRaises(ValueError):
            install.hook_document(hooks, self.root / "app")

    def test_legacy_desktop_hooks_migrate_without_duplicates(self):
        app = self.root / "app"
        hooks = self.root / "hooks.json"
        old = f"/usr/bin/python3 -I {app}/desktop/codex_hook.py"
        document = {"hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": old, "timeout": 3},
            {"type": "command", "command": "/usr/bin/true"}]}]}}
        hooks.write_text(json.dumps(document))
        migrated, changed = install.hook_document(hooks, app)
        self.assertIn("Stop", changed)
        commands = [item["command"] for group in migrated["hooks"]["Stop"]
                    for item in group["hooks"]]
        self.assertEqual(commands, [install.hook_command(app), "/usr/bin/true"])
        hooks.write_text(json.dumps(migrated))
        again, changed = install.hook_document(hooks, app)
        self.assertEqual(changed, [])
        self.assertEqual(again, migrated)
        removed, changed = install.hook_document(hooks, app, remove=True)
        self.assertIn("Stop", changed)
        self.assertEqual(removed["hooks"]["Stop"][0]["hooks"],
                         [{"type": "command", "command": "/usr/bin/true"}])

    def test_relay_setup_reuses_source_credential_and_respects_sharing(self):
        home = self.root / "home"
        app = home / ".local/lib/paceman"
        state = home / ".local/state/paceman"
        (app / "service").mkdir(parents=True)
        (app / "service/push.py").touch()
        Store(state / "hub.sqlite3")
        (state / "push-venv/bin").mkdir(parents=True)
        (state / "push-venv/bin/python3").touch()
        calls = []
        def fake_run(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0)
        with patch.object(install_push.Path, "home", return_value=home), \
             patch.object(install_push.subprocess, "run", side_effect=fake_run), \
             patch.dict(os.environ, {"XDG_STATE_HOME": str(home / ".local/state")}):
            install_push.configure("https://relay.example")
            config = state / "private/apns.json"
            first = json.loads(config.read_text())
            self.assertEqual(first["sourceID"], Store(state / "hub.sqlite3").metadata("source_id"))
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            install_push.configure("https://relay.example")
            self.assertEqual(json.loads(config.read_text()), first)
            self.assertEqual(sum(call[-2:] == ["restart", install.SERVICE] for call in calls), 2)
            install_push.configure("https://relay-new.example")
            changed = json.loads(config.read_text())
            self.assertEqual(changed["relayURL"], "https://relay-new.example")
            self.assertEqual(changed["credential"], first["credential"])
            (state / "sharing-paused").touch()
            calls.clear()
            install_push.configure("https://relay.example")
            self.assertFalse(any("restart" in call for call in calls))
            with self.assertRaises(ValueError):
                install_push.configure("http://relay.example")

    def test_unit_paths_escape_systemd_specifiers(self):
        value = install.render_unit(Path('/home/test/50% "app"'), self.root / "state")
        self.assertIn('50%% \\"app\\"', value)
