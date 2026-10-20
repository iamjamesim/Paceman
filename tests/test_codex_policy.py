import unittest
from unittest.mock import Mock, patch

from service.codex_policy import read_browser_policy


class BrowserPolicyTests(unittest.TestCase):
    def test_managed_policy_defaults_require_a_successful_read(self):
        for result, expected in [({}, None), ({'requirements': None}, True),
                ({'requirements': {}}, True), ({'requirements': {'browserUse': None}}, True),
                ({'requirements': {'browserUse': {'allowGlobalPersistentApproval': False}}}, False),
                ({'requirements': {'browserUse': {'allowGlobalPersistentApproval': True}}}, True),
                ({'requirements': {'browserUse': {'allowGlobalPersistentApproval': 'yes'}}}, None)]:
            with self.subTest(result=result), patch('service.codex_policy.codex_binary', return_value='/codex'), \
                    patch('service.codex_policy.subprocess.Popen', return_value=Mock()) as process, \
                    patch('service.codex_policy._send') as send, \
                    patch('service.codex_policy._response', side_effect=[{'version': 'test'}, result]):
                self.assertIs(read_browser_policy(), expected)
                self.assertEqual([c.args[1]['method'] for c in send.call_args_list],
                                 ['initialize', 'initialized', 'configRequirements/read'])
                process.return_value.terminate.assert_called_once()
                process.return_value.stdin.close.assert_called_once()
                process.return_value.stdout.close.assert_called_once()

    def test_missing_binary_and_initialization_failure_are_unknown(self):
        with patch('service.codex_policy.codex_binary', return_value=None):
            self.assertIsNone(read_browser_policy())
        with patch('service.codex_policy.codex_binary', return_value='/codex'), \
                patch('service.codex_policy.subprocess.Popen', return_value=Mock()) as process, \
                patch('service.codex_policy._send'), patch('service.codex_policy._response', return_value={}):
            self.assertIsNone(read_browser_policy())
            process.return_value.terminate.assert_called_once()
