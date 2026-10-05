import datetime as dt
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from service import claude_limits as limits
from service.macos import MacSource
from service.hub import Store

NOW = 1800000000

def reading(used=25, reset=NOW+3600):
    return {"utilization": used, "resets_at": dt.datetime.fromtimestamp(reset, dt.timezone.utc).isoformat()}

def credentials(token="private-token"):
    return {"claudeAiOauth": {"accessToken": token, "expiresAt": (NOW+3600)*1000, "scopes": ["user:profile"]}}

class ClaudeUsageTests(unittest.TestCase):
    def test_both_windows_keep_their_own_resets_and_observation(self):
        values = limits.parse_claude_allowances({"five_hour": reading(25), "seven_day": reading(92, NOW+86400)}, NOW)
        self.assertEqual([(v["provider"], v["remaining"], v["window"], v["resetsAt"], v["updatedAt"]) for v in values],
            [("claude",75,2,NOW+3600,NOW),("claude",8,1,NOW+86400,NOW)])
    def test_invalid_future_or_reset_readings_do_not_claim_quota(self):
        for used in (True, -1, 101, float("nan"), float("inf"), "25"):
            self.assertEqual(limits.parse_claude_allowances({"five_hour": reading(used)}, NOW), [])
        self.assertEqual(limits.parse_claude_allowances({"five_hour": reading(reset=NOW)}, NOW), [])
        self.assertEqual(limits.parse_claude_allowances({"five_hour": {"utilization": 25, "resets_at": "2027-01-15T08:00:00"}}, NOW), [])
    def test_oauth_is_read_only_and_bounded(self):
        response = io.BytesIO(json.dumps({"five_hour": reading()}).encode())
        with patch.object(limits, "credentials", return_value=(credentials(), "ready")), \
             patch.object(limits, "build_opener") as opener:
            opener.return_value.open.return_value = response
            values, status = limits.read_claude_allowances(now=NOW)
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(request.full_url, "https://api.anthropic.com/api/oauth/usage")
            self.assertIsNone(request.data)
            self.assertEqual(opener.return_value.open.call_args.kwargs["timeout"], 8)
            self.assertEqual((values[0]["remaining"], status), (75,"ready"))
            self.assertIsNone(limits._NoRedirect().redirect_request(None,None,None,None,None,None))
    def test_expiry_and_scope_require_claude_to_reauthenticate(self):
        for doc in ({}, {"claudeAiOauth": {"accessToken":"x", "expiresAt": NOW*1000}},
                    {"claudeAiOauth": {"accessToken":"x", "scopes":["user:inference"]}}):
            with patch.object(limits, "credentials", return_value=(doc,"ready")), patch.object(limits, "build_opener") as opener:
                self.assertEqual(limits.read_claude_allowances(now=NOW), ([],"sign_in_needed"))
                opener.assert_not_called()
    def test_transient_failure_retains_time_but_auth_failure_clears(self):
        for status, expected in ((429,(None,"unavailable")),(503,(None,"unavailable")),(401,([],"sign_in_needed"))):
            with patch.object(limits, "credentials", return_value=(credentials(),"ready")), patch.object(limits, "build_opener") as opener:
                opener.return_value.open.side_effect = HTTPError("https://api.anthropic.com",status,"error",{},None)
                self.assertEqual(limits.read_claude_allowances(now=NOW),expected)
    def test_new_sign_in_does_not_inherit_previous_cache_on_network_failure(self):
        reader = limits.ClaudeUsageReader()
        with patch.object(limits, "credentials", return_value=(credentials("first"),"ready")), \
             patch.object(limits, "read_claude_allowances", return_value=(None,"unavailable")):
            self.assertEqual(reader(),([],"unavailable"))
            self.assertEqual(reader(),(None,"unavailable"))
        with patch.object(limits, "credentials", return_value=(credentials("second"),"ready")), \
             patch.object(limits, "read_claude_allowances", return_value=(None,"unavailable")):
            self.assertEqual(reader(),([],"unavailable"))
    def test_custom_profile_never_borrows_default_keychain(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ,{"CLAUDE_CONFIG_DIR":temporary}), \
             patch.object(limits,"keychain_credentials") as keychain:
            self.assertEqual(limits.credentials(),(None,"sign_in_needed"))
            keychain.assert_not_called()
            (Path(temporary)/".credentials.json").write_text(json.dumps(credentials()))
            self.assertEqual(limits.credentials(),(credentials(),"ready"))
    def test_explicit_default_profile_can_use_noninteractive_keychain(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(Path,"home",return_value=Path(temporary)), \
             patch.dict(os.environ,{"CLAUDE_CONFIG_DIR":str(Path(temporary)/".claude")}), \
             patch.object(limits,"keychain_credentials",return_value=(None,"access_needed")) as keychain:
            self.assertEqual(limits.credentials(),(None,"access_needed"))
            keychain.assert_called_once_with(allow_prompt=False)
    def test_source_keeps_providers_independent_on_refresh_and_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            store=Store(Path(temporary)/"hub.sqlite3")
            codex=dict(provider="codex",remaining=70,window=1,windowDurationMins=10080,updatedAt=NOW,resetsAt=NOW+86400)
            claude=dict(provider="claude",remaining=10,window=2,windowDurationMins=300,updatedAt=NOW,resetsAt=NOW+3600)
            with MacSource(store,socket_path=Path(temporary)/"hook.sock",allowance_reader=lambda:[codex],
                           claude_allowance_reader=lambda:([claude],"ready")) as source:
                source._refresh_allowance();source._refresh_claude_allowance()
                event=store.snapshot()["eventID"]
                self.assertEqual(store.snapshot()["allowance"],codex)
                self.assertEqual(store.snapshot()["allowances"],[codex,claude])
                source.claude_allowance_reader=lambda:(None,"unavailable")
                source._refresh_claude_allowance()
                self.assertEqual(store.snapshot()["allowances"],[codex,claude])
                self.assertEqual(store.snapshot()["eventID"],event)
                source.claude_allowance_reader=lambda:([],"sign_in_needed")
                source._refresh_claude_allowance()
                self.assertEqual(store.snapshot()["allowances"],[codex])
    def test_disabled_provider_cannot_reopen_activity(self):
        with tempfile.TemporaryDirectory() as temporary:
            store=Store(Path(temporary)/"hub.sqlite3")
            with MacSource(store,socket_path=Path(temporary)/"hook.sock",providers=["codex"]) as source:
                self.assertFalse(source.receive(dict(command="agent-event",provider="claude",session="one",turn="one",event="working")))
                self.assertEqual(store.snapshot()["sessions"],[])
