import http.client
import io
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from desktop import install
from desktop.control import private_endpoint, read_status, set_sharing, pair_phone, remove_access
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
        client = self.store.redeem(invitation["invitation"])
        self.status.publish(force=True)
        value = read_status(self.path)
        self.assertTrue(value["running"])
        self.assertFalse(value["phoneRecent"])
        self.assertEqual(value["pairedPhones"], 1)
        self.assertNotIn(client["credential"], self.path.read_text())
        self.assertEqual(value["clients"][0]["id"], client["clientID"])
        self.assertIsNone(value["clients"][0]["name"])
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
            client = self.store.redeem(invitation["invitation"])
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
        first, second = [self.store.redeem(self.store.invite('https://test.example')['invitation']) for _ in range(2)]
        self.store.push_device(first['credential'], {'deviceToken': 'ab' * 32, 'environment': 'development', 'mode': 'alert'})
        (self.root / 'sharing-paused').write_text('{}')
        with patch('desktop.control.state_directory', return_value=self.root), patch('desktop.control.status_path', return_value=self.root / 'absent'):
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
        with patch("desktop.control.pause_path", return_value=marker), patch("desktop.control.subprocess.run") as run:
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
        client = self.store.redeem(self.store.invite("https://test.example")["invitation"])
        with patch("desktop.control.state_directory", return_value=self.root), \
             patch("desktop.control.status_path", return_value=self.root / "missing.json"):
            value = read_status()
            self.assertFalse(value["sharingEnabled"])
            self.assertFalse(value["running"])
            self.assertEqual(value["pairedPhones"], 1)
            self.assertNotIn(client["credential"], json.dumps(value))

    @unittest.skipUnless(Path("/usr/bin/qrencode").exists(), "qrencode is optional")
    def test_panel_pairing_returns_only_image_location_and_expiry(self):
        config = {"TCP": {"8443": {"HTTPS": True}}, "Web": {
            "test.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8765"}}}}}
        original_run = subprocess.run
        def command(args, **kwargs):
            if args[0] == "/usr/bin/tailscale":
                return subprocess.CompletedProcess(args, 0, json.dumps(config), "")
            return original_run(args, **kwargs)
        output = io.StringIO()
        with patch("desktop.control.state_directory", return_value=self.root), \
             patch("desktop.control.read_status", return_value={"running": True}), \
             patch("desktop.control.subprocess.run", side_effect=command), \
             patch("desktop.control.urllib.request.urlopen"), redirect_stdout(output):
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
        self.root = Path(self.temp.name)

    def test_sqlite_migration_preserves_pairings_and_never_overwrites_installed_database(self):
        source = Store(self.root / "checkout/hub.sqlite3")
        client = source.redeem(source.invite("https://test.example")["invitation"])
        target = self.root / "state/hub.sqlite3"
        self.assertTrue(install.migrate_database(source.path, target))
        installed = Store(target)
        self.assertEqual(source.metadata("source_id"), installed.metadata("source_id"))
        self.assertTrue(installed.authorized(client["credential"]))
        installed.revoke(client["clientID"])
        self.assertFalse(install.migrate_database(source.path, target))
        self.assertFalse(installed.authorized(client["credential"]))

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
        for directory in ("desktop", "service", "systemd"):
            shutil.copytree(install.ROOT / directory, source / directory,
                            ignore=shutil.ignore_patterns("__pycache__"))
        old = Store(source / ".runtime/hub.sqlite3")
        old_id = old.metadata("source_id")
        home = self.root / "home"
        calls = []
        def fake_run(*args, **kwargs):
            calls.append(args)
            output = json.dumps({"running": True, "startedAt": time.time()}) if args[-1] == "status" else "ok"
            return subprocess.CompletedProcess(args, 0, output, "")
        with patch.object(install, "ROOT", source), patch.object(install.Path, "home", return_value=home), \
             patch.object(install, "run", side_effect=fake_run), \
             patch.dict(os.environ, {"XDG_STATE_HOME": str(home / ".local/state"), "XDG_CONFIG_HOME": str(home / ".config")}), \
             patch.object(install.socket, "socket"):
            for _ in range(2):
                with patch("sys.argv", ["install.py", "install"]):
                    install.main()
            self.assertEqual(Store(home / ".local/state/paceman/hub.sqlite3").metadata("source_id"), old_id)
            unit = (home / ".config/systemd/user/paceman-source.service").read_text()
            self.assertNotIn(str(source), unit)
            self.assertNotIn("@APP@", unit)
            self.assertTrue((home / ".local/bin/pacemanctl").exists())
            (home / ".local/state/paceman/sharing-paused").write_text('{"paused":true}')
            calls.clear()
            with patch("sys.argv", ["install.py", "install"]):
                install.main()
            self.assertNotIn(("/usr/bin/systemctl", "--user", "enable", "--now", "paceman-source.service"), calls)
            self.assertIn(("/usr/bin/systemctl", "--user", "disable", "--now", "paceman-source.service"), calls)
            with patch("sys.argv", ["install.py", "uninstall"]):
                install.main()
            self.assertTrue((home / ".local/state/paceman/hub.sqlite3").exists())
            self.assertFalse((home / ".local/bin/pacemanctl").exists())
            self.assertFalse((home / ".local/lib/paceman").exists())

    def test_unit_paths_escape_systemd_specifiers(self):
        value = install.render_unit(Path('/home/test/50% "app"'), self.root / "state")
        self.assertIn('50%% \\"app\\"', value)
