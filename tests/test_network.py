import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from service import network


def route(host="test.ts.net:8443", port="8443", *, funnel=False):
    value = {"TCP": {port: {"HTTPS": True}}, "Web": {
        host: {"Handlers": {"/": {"Proxy": network.SOURCE}}}}}
    if funnel:
        value["AllowFunnel"] = {host: True}
    return value


class PrivateRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)

    def test_reuses_existing_route_without_claiming_it(self):
        with patch.object(network, "_binary", return_value="tailscale"), \
             patch.object(network, "_config", return_value=route()), \
             patch.object(network, "_verify") as verify, \
             patch.object(network.subprocess, "run") as run:
            self.assertEqual(network.ensure_private_route(self.state), "https://test.ts.net:8443")
        verify.assert_called_once_with("https://test.ts.net:8443")
        run.assert_not_called()
        self.assertFalse((self.state / network.ROUTE_MARKER).exists())

    def test_finder_path_finds_installed_tailscale(self):
        binary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        with patch.object(network.sys, "platform", "darwin"), \
             patch.object(network.shutil, "which", return_value=None), \
             patch.object(Path, "is_file", lambda path: str(path) == binary), \
             patch.object(network.os, "access", return_value=True):
            self.assertEqual(network._binary(), binary)

    def test_creates_free_private_port_and_removes_only_its_unchanged_route(self):
        existing = {"TCP": {"8443": {"HTTPS": True}}, "Web": {
            "other.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9999"}}}}}
        created = {"TCP": {**existing["TCP"], "8444": {"HTTPS": True}}, "Web": {
            **existing["Web"], "test.ts.net:8444": {"Handlers": {"/": {"Proxy": network.SOURCE}}}}}
        with patch.object(network, "_binary", return_value="tailscale"), \
             patch.object(network, "_config", side_effect=[existing, created, created]), \
             patch.object(network, "_verify"), \
             patch.object(network.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(network.ensure_private_route(self.state), "https://test.ts.net:8444")
            self.assertEqual(json.loads((self.state / network.ROUTE_MARKER).read_text())["port"], 8444)
            self.assertTrue(network.remove_owned_route(self.state))
        self.assertEqual(run.call_args_list[0].args[0],
                         ["tailscale", "serve", "--bg", "--https=8444", network.SOURCE])
        self.assertEqual(run.call_args_list[1].args[0], ["tailscale", "serve", "--https=8444", "off"])
        self.assertFalse((self.state / network.ROUTE_MARKER).exists())

    def test_public_or_ambiguous_source_route_is_never_replaced(self):
        for config in (route(funnel=True), {"TCP": {"8443": {"HTTPS": True}, "8444": {"HTTPS": True}},
                     "Web": {**route()["Web"], **route("other.ts.net:8444", "8444")["Web"]}}):
            with self.subTest(config=config), patch.object(network, "_binary", return_value="tailscale"), \
                 patch.object(network, "_config", return_value=config), \
                 patch.object(network.subprocess, "run") as run:
                with self.assertRaises(network.RouteSetupError):
                    network.ensure_private_route(self.state)
                run.assert_not_called()

    def test_missing_serve_config_is_empty(self):
        with patch.object(network.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "No serve config", "")):
            self.assertEqual(network._config("tailscale"), {})

    def test_private_route_must_reach_the_authenticated_source(self):
        unauthorized = urllib.error.HTTPError("https://test.ts.net:8443/v1/snapshot", 401,
                                               "Unauthorized", None, None)
        with patch.object(network.urllib.request, "urlopen", side_effect=unauthorized):
            network._verify("https://test.ts.net:8443")
        with patch.object(network.urllib.request, "urlopen"):
            with self.assertRaises(network.RouteSetupError):
                network._verify("https://test.ts.net:8443")

    def test_does_not_remove_a_route_the_user_changed(self):
        network._remember_route(self.state, "test.ts.net:8443", 8443)
        changed = route()
        changed["Web"]["test.ts.net:8443"]["Handlers"]["/extra"] = {"Proxy": "http://127.0.0.1:9999"}
        with patch.object(network, "_binary", return_value="tailscale"), \
             patch.object(network, "_config", return_value=changed), \
             patch.object(network.subprocess, "run") as run:
            self.assertFalse(network.remove_owned_route(self.state))
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
