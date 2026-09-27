import copy
import datetime as dt
import json
from pathlib import Path
import tempfile
import unittest

from service import allowance as daemon


class AllowanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "codex.json"
        self.now = 1800000000
        self.record = {
            "schemaVersion": 1, "id": "codex", "updatedAt": self.iso(self.now),
            "usageStatusText": "",
            "limits": [{"label": "Weekly (7-day)", "percent": .21,
                        "resetsAt": self.iso(self.now + 86400)}],
        }

    @staticmethod
    def iso(epoch):
        return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()

    def read(self, record=None, now=None):
        self.path.write_text(json.dumps(self.record if record is None else record))
        return daemon.read_codex_allowance(self.path, self.now if now is None else now)

    def test_remaining_not_used(self):
        self.assertEqual(self.read(), {"remaining": 79, "window": 1,
                                      "updatedAt": self.now, "resetsAt": self.now + 86400})

    def test_selects_most_depleted_window_with_its_reset(self):
        self.record["limits"].append({"label": "5h window", "percent": .9,
                                      "resetsAt": self.iso(self.now + 600)})
        value = self.read()
        self.assertEqual((value["remaining"], value["window"], value["resetsAt"]),
                         (10, 2, self.now + 600))

    def test_equal_usage_prefers_weekly_window(self):
        self.record["limits"].insert(0, {"label": "5h window", "percent": .21,
                                          "resetsAt": self.iso(self.now + 600)})
        self.assertEqual(self.read()["window"], 1)

    def test_zero_and_full_are_valid(self):
        for used, left in ((0, 100), (1, 0)):
            self.record["limits"][0]["percent"] = used
            self.assertEqual(self.read()["remaining"], left)

    def test_invalid_percentages_are_unavailable(self):
        for value in (None, True, "0.21", -1, 21, float("nan"), float("inf")):
            with self.subTest(value=value):
                self.record["limits"][0]["percent"] = value
                self.assertEqual(self.read()["remaining"], 255)

    def test_missing_invalid_and_oversized_files(self):
        for raw in (None, "{", " " * 262145):
            if raw is not None:
                self.path.write_text(raw)
            self.assertEqual(daemon.read_codex_allowance(self.path, self.now)["remaining"], 255)

    def test_incompatible_records_are_unavailable(self):
        for key, value in (("schemaVersion", 2), ("schemaVersion", True),
                           ("id", "claude"), ("limits", []), ("limits", [None]),
                           ("usageStatusText", "Sign-in expired"), ("retryAdvised", True)):
            with self.subTest(key=key, value=value):
                record = copy.deepcopy(self.record)
                record[key] = value
                self.assertEqual(self.read(record)["remaining"], 255)
        self.assertEqual(self.read([])["remaining"], 255)

    def test_stale_future_and_timezone_less_timestamp(self):
        self.assertEqual(self.read(now=self.now + 1800)["remaining"], 79)
        for now in (self.now + 1801, self.now - 1):
            self.assertEqual(self.read(now=now)["remaining"], 255)
        self.record["updatedAt"] = "2027-01-15T08:00:00"
        self.assertEqual(self.read()["remaining"], 255)

    def test_reset_does_not_imply_refill(self):
        self.record["limits"][0]["resetsAt"] = self.iso(self.now)
        self.assertEqual(self.read()["remaining"], 255)

    def test_unknown_window_does_not_silently_disappear(self):
        self.record["limits"].append({"label": "New model limit", "percent": .95,
                                      "resetsAt": self.iso(self.now + 500)})
        self.assertEqual(self.read()["remaining"], 255)

    def test_extra_fields_are_ignored(self):
        self.record["newField"] = "irrelevant"
        self.assertEqual(self.read()["remaining"], 79)

