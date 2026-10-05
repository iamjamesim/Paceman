import json
from pathlib import Path
import plistlib
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

import macos.install_push as mac_push
import macos.uninstall as mac_uninstall

from service.hub import Store
from service.push import RelayConfig


class RelaySetupTests(unittest.TestCase):
    def test_relay_image_can_import_its_entry_point(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory)
            for line in (root / "Dockerfile.relay").read_text().splitlines():
                if not line.startswith("COPY "):
                    continue
                *sources, destination = shlex.split(line)[1:]
                target = image / destination
                target.mkdir(parents=True, exist_ok=True)
                for source in sources:
                    shutil.copy2(root / source, target / Path(source).name)
            result = subprocess.run([sys.executable, "-I", "-c",
                "import sys; sys.path.insert(0, '.'); import service.relay"],
                cwd=image, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)

    def setUp(self):
        self.source = str(uuid.uuid4())
        self.source_key = secrets.token_urlsafe(32)

    def test_source_config_requires_https_and_random_credential(self):
        value = {"relayURL": "https://relay.example", "sourceID": self.source,
                 "credential": self.source_key}
        self.assertEqual(RelayConfig.load(value).source_id, self.source)
        for bad in ({**value, "relayURL": "http://relay.example"},
                    {**value, "relayURL": "https://user@relay.example"},
                    {**value, "credential": "short"}, {**value, "keyPath": "secret.p8"}):
            with self.assertRaises(ValueError):
                RelayConfig.load(bad)

    def test_mac_install_generates_source_credential_without_apns_key(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / "installed"
        (root / "lib/service").mkdir(parents=True)
        (root / "lib/service/push.py").touch()
        source_id = Store(root / "data/hub.sqlite3").metadata("source_id")
        private = root / "private"
        private.mkdir()
        key = private / "apns-key.p8"
        key.write_text("legacy")
        plist = Path(temporary.name) / "source.plist"
        plist.write_bytes(plistlib.dumps({"ProgramArguments": ["/tmp/PacemanBackground"]}))
        venv = root / "push-venv"
        (venv / "bin").mkdir(parents=True)
        (venv / "bin/python3").touch()
        with (patch.multiple(mac_push, ROOT=root, PRIVATE=private, KEY=key,
                             WATCH_KEY=private / "watch-key.p8", CONFIG=private / "apns.json",
                             VENV=venv, SOURCE_PLIST=plist, PLIST=Path(temporary.name) / "absent.plist"),
              patch.object(mac_push.subprocess, "run")):
            mac_push.install(relay_url="https://relay.example")
            initial_credential = json.loads((private / "apns.json").read_text())["credential"]
            mac_push.install(relay_url="https://relay-new.example")
        value = json.loads((private / "apns.json").read_text())
        self.assertEqual(value["sourceID"], source_id)
        self.assertEqual(value["relayURL"], "https://relay-new.example")
        self.assertEqual(value["credential"], initial_credential)
        self.assertNotIn("keyPath", value)
        self.assertFalse(key.exists())
        self.assertEqual(private.stat().st_mode & 0o777, 0o700)
        self.assertEqual((private / "apns.json").stat().st_mode & 0o777, 0o600)

    def test_mac_push_dependency_failure_does_not_publish_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "installed"
            (root / "lib/service").mkdir(parents=True)
            (root / "lib/service/push.py").touch()
            Store(root / "data/hub.sqlite3")
            plist = Path(temporary) / "source.plist"
            plist.write_bytes(plistlib.dumps({"ProgramArguments": ["/tmp/PacemanBackground"]}))
            venv = root / "push-venv"
            (venv / "bin").mkdir(parents=True)
            (venv / "bin/python3").touch()
            with (patch.multiple(mac_push, ROOT=root, PRIVATE=root / "private",
                                 CONFIG=root / "private/apns.json", VENV=venv,
                                 SOURCE_PLIST=plist, PLIST=Path(temporary) / "absent.plist"),
                  patch.object(mac_push.subprocess, "run", side_effect=OSError("dependency install failed"))):
                with self.assertRaises(OSError):
                    mac_push.install(relay_url="https://relay.example")
            self.assertFalse((root / "private/apns.json").exists())

    def test_prebuilt_mac_relay_uses_bundled_python_without_pip(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "installed"
            (root / "lib/service").mkdir(parents=True)
            (root / "lib/service/push.py").touch()
            Store(root / "data/hub.sqlite3")
            app = base / "Applications/Paceman.app"
            bundled = app / "Contents/Resources/python/bin/python3"
            bundled.parent.mkdir(parents=True)
            bundled.touch()
            plist = base / "source.plist"
            plist.write_bytes(plistlib.dumps({"ProgramArguments": [
                str(app / "Contents/MacOS/PacemanBackground"), str(bundled), str(root),
                str(root / "push-venv/bin/python3")]}))
            calls = []

            def command(arguments, **_):
                calls.append(arguments)
                return subprocess.CompletedProcess(arguments, 0)

            with patch.multiple(mac_push, ROOT=root, APP=app, PRIVATE=root / "private",
                                CONFIG=root / "private/apns.json", VENV=root / "push-venv",
                                SOURCE_PLIST=plist, PLIST=base / "absent.plist"), \
                 patch.object(mac_push.subprocess, "run", side_effect=command):
                mac_push.install(relay_url="https://relay.example")
            self.assertFalse(any("pip" in arguments for arguments in calls))
            self.assertEqual(plistlib.loads(plist.read_bytes())["ProgramArguments"][3], str(bundled))

    def test_mac_uninstall_revokes_source_before_discarding_credential(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        config = Path(temporary.name) / "relay.json"
        config.write_text(json.dumps({"relayURL": "https://relay.example", "sourceID": self.source,
                                      "credential": self.source_key}))
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): pass
        class Opener:
            def open(self, request, timeout):
                self.assert_request(request, timeout)
                return Response()
            def assert_request(self, request, timeout):
                assert request.full_url == "https://relay.example/v2/sources"
                assert request.get_method() == "DELETE"
                assert timeout == 5
        with patch.object(mac_uninstall, "build_opener", return_value=Opener()):
            self.assertIsNone(mac_uninstall.revoke_relay_source(config))


if __name__ == "__main__":
    unittest.main()
