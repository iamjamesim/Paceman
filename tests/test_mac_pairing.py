import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from macos import control
from macos.paths import installed_app


class MacPairingTests(unittest.TestCase):
    def test_relocated_bundled_runtime_selects_the_app_that_is_running(self):
        for app in (Path("/Applications/Paceman.app"), Path.home() / "Applications/Paceman.app"):
            with self.subTest(app=app), patch("macos.paths.sys.executable", str(app / "Contents/Resources/python/bin/python3.14")):
                self.assertEqual(installed_app(), app)

    def test_recorded_app_is_restricted_to_recognized_install_locations(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            marker = home / "Library/Application Support/Paceman/installed-app"
            marker.parent.mkdir(parents=True)
            with patch("macos.paths.Path.home", return_value=home), \
                 patch("macos.paths.sys.executable", "/opt/homebrew/bin/python3"):
                marker.write_text("/Applications/Paceman.app\n")
                self.assertEqual(installed_app(), Path("/Applications/Paceman.app"))
                marker.write_text("/Applications/Another.app\n")
                self.assertEqual(installed_app(), home / "Applications/Paceman.app")

    def test_finder_path_finds_installed_tailscale(self):
        with patch.object(control.shutil, "which", return_value=None), \
             patch.object(Path, "is_file", lambda path: str(path) == "/usr/local/bin/tailscale"), \
             patch.object(control.os, "access", return_value=True):
            self.assertEqual(control.tailscale_binary(), "/usr/local/bin/tailscale")

    def test_app_install_without_cli_symlink_is_discovered(self):
        binary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        with patch.object(control.shutil, "which", return_value=None), \
             patch.object(Path, "is_file", lambda path: str(path) == binary), \
             patch.object(control.os, "access", return_value=True):
            self.assertEqual(control.tailscale_binary(), binary)

    def test_pairing_retries_after_tailscale_reconnects(self):
        route = {"TCP": {"8443": {"HTTPS": True}}, "Web": {
            "computer.example.ts.net:8443": {"Handlers": {
                "/": {"Proxy": "http://127.0.0.1:8765"}}}}}
        disconnected = subprocess.CalledProcessError(1, "tailscale")
        connected = subprocess.CompletedProcess("tailscale", 0, json.dumps(route))
        with patch.object(control, "status", return_value={"running": True}), \
             patch.object(control, "tailscale_binary", return_value="/usr/local/bin/tailscale"), \
             patch.object(control.subprocess, "run", side_effect=[disconnected, connected]), \
             patch.object(control.urllib.request, "urlopen") as request, \
             patch.object(control, "Store") as store:
            with self.assertRaisesRegex(ValueError, "Open Tailscale, reconnect"):
                control.pairing()
            store.assert_not_called()
            request.side_effect = control.urllib.error.HTTPError("https://computer.example.ts.net:8443/v1/snapshot", 401, "Unauthorized", {}, io.BytesIO())
            store.return_value.invite.return_value = {"schema": 1}
            with redirect_stdout(io.StringIO()) as output:
                control.pairing()
            self.assertEqual(json.loads(output.getvalue()), {"schema": 1})
            store.return_value.invite.assert_called_once_with("https://computer.example.ts.net:8443")
