import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

from macos.support import report
from service.hub import Store
from tests.identity import device


class MacSupportReportTests(unittest.TestCase):
    def test_report_explains_delivery_without_exporting_private_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / "data/hub.sqlite3")
            invitation = store.invite("https://private.example")
            client = store.redeem(invitation["invitation"], device=device())
            secret = "very-secret-source-credential"
            config = root / "private/apns.json"
            config.parent.mkdir()
            config.write_text(json.dumps({"credential": secret}))
            with store.connect() as db:
                db.execute("INSERT INTO push_devices(client_id,token,environment,cursor,last_result) "
                           "VALUES (?,?,?,?,?)",
                           (client["clientID"], "ab" * 32, "production", 1, "Accepted"))
            log = root / "data/push-delivery.jsonl"
            log.write_text(json.dumps({"at": 100, "stage": "apns_accepted", "status": 200,
                                       "reason": "Accepted",
                                       "event": secret, "clientID": client["clientID"],
                                       "token": "ab" * 32}) + "\n")
            app = root / "Paceman.app"
            info = app / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1", "CFBundleVersion": "1"}))
            status = {"running": True, "sharingEnabled": False, "clients": [{"name": "Test iPhone"}],
                      "computerName": "private-mac", "lastAgentEventAt": 90,
                      "lastPhoneFetchAt": 95, "missingHooks": ["Stop"]}

            value = report(root, status, app, now=101)
            self.assertEqual(value["appVersion"], "0.1")
            self.assertEqual(value["build"], "1")
            self.assertTrue(value["source"]["databaseReadable"])
            self.assertEqual(value["source"]["missingHooks"], ["Stop"])
            self.assertFalse(value["source"]["sharingEnabled"])
            self.assertEqual(value["push"]["recentDelivery"],
                             [{"at": 100, "stage": "apns_accepted", "status": 200,
                               "reason": "Accepted"}])
            self.assertEqual(value["push"]["destinations"][0]["kind"], "alert")
            exported = json.dumps(value)
            for private in (secret, client["credential"], client["clientID"],
                            "Test iPhone", "private-mac", "private.example", "ab" * 32):
                self.assertNotIn(private, exported)
            self.assertEqual(value["sourceSupportID"],
                             hashlib.sha256(store.metadata("source_id").encode()).hexdigest()[:12])

    def test_report_works_before_source_is_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            value = report(root, {"running": False, "sharingEnabled": True}, root / "missing.app", now=1)
            self.assertIsNone(value["sourceSupportID"])
            self.assertFalse(value["source"]["databaseReadable"])
            self.assertFalse(value["push"]["configured"])
            self.assertEqual(value["push"]["destinations"], [])

    def test_report_remains_available_for_unreadable_source_database(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "data/hub.sqlite3"
            database.parent.mkdir()
            database.write_text("not a database")
            value = report(root, {"running": False}, root / "missing.app", now=1)
            self.assertFalse(value["source"]["databaseReadable"])
            self.assertEqual(value["push"]["destinations"], [])
