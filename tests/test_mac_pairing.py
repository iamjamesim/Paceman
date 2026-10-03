import io
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from macos import control
from macos.paths import installed_app
from service.network import RouteSetupError


class MacPairingTests(unittest.TestCase):
    def test_pausing_sharing_prevents_pairing_even_with_a_recent_heartbeat(self):
        with patch.object(control, "status", return_value={"running": True, "sharingEnabled": False}), \
             patch.object(control, "Store") as store:
            with self.assertRaisesRegex(ValueError, "Turn on Sharing"):
                control.pairing()
            store.assert_not_called()

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

    def test_failed_route_does_not_create_an_invitation(self):
        with patch.object(control, "status", return_value={"running": True, "sharingEnabled": True}), \
             patch.object(control, "ensure_private_route", side_effect=RouteSetupError("Connect Tailscale")), \
             patch.object(control, "Store") as store:
            with self.assertRaisesRegex(ValueError, "Connect Tailscale"):
                control.pairing()
            store.assert_not_called()

    def test_pairing_prepares_route_before_inviting(self):
        with patch.object(control, "status", return_value={"running": True, "sharingEnabled": True}), \
             patch.object(control, "ensure_private_route", return_value="https://computer.example.ts.net:8443") as route, \
             patch.object(control, "Store") as store:
            store.return_value.invite.return_value = {"schema": 1}
            with redirect_stdout(io.StringIO()) as output:
                control.pairing()
            self.assertEqual(json.loads(output.getvalue()), {"schema": 1})
            route.assert_called_once_with(control.ROOT)
            store.return_value.invite.assert_called_once_with("https://computer.example.ts.net:8443")
