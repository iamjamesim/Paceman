"""Provider schemas are decoded on the desktop; unknown arguments survive."""
import json
import unittest

from service.interaction_content import normalize_approval
from service.interactions import BrokerError, InteractionBroker


def request(tool='Bash', input=None, choices=None):
    return dict(provider='claude', sessionID='a' * 64, kind='approval', title='Allow tool?', detail='',
                contentVersion=2, approval={'toolName': tool, 'workingDirectory': '/tmp/My App',
                    'input': input if input is not None else {'command': 'printf 日本語', 'description': 'Verify output', 'timeout': 120000}},
                responseOptions=choices if choices is not None else [
                    {'id': 'once', 'label': 'Allow once'}, {'id': 'session', 'label': 'Allow for this session'},
                    {'id': 'decline', 'label': 'Decline'}])


class ApprovalContentTests(unittest.TestCase):
    def test_documented_commands_and_files_decode_at_source_and_preserve_extensions(self):
        for provider in ('codex', 'claude'):
            for tool in ('Bash', 'PowerShell', 'apply_patch'):
                raw = request(tool)['approval']
                result = normalize_approval(provider, raw)
                self.assertEqual(result['input'], raw['input'])
                self.assertEqual(result['action']['text'], 'printf 日本語')
                self.assertEqual(result['action']['kind'], 'patch' if tool == 'apply_patch' else 'command')
                self.assertEqual(result['reason'], 'Verify output')
                self.assertTrue(result['hasAdditionalInput'])
        for tool, fields, kind in [('Write', {'file_path': '/tmp/a', 'content': ''}, 'fileWrite'),
                                  ('Edit', {'file_path': '/tmp/a', 'old_string': 'before\n', 'new_string': 'after\n', 'replace_all': True}, 'fileEdit')]:
            fields['future_extension'] = {'keep': [True, None, 'exactly']}
            raw = request(tool, fields)['approval']
            result = normalize_approval('claude', raw)
            self.assertEqual(result['action']['kind'], kind)
            self.assertEqual(result['action']['filePath'], '/tmp/a')
            self.assertEqual(result['input'], fields)
            self.assertTrue(result['hasAdditionalInput'])
            self.assertEqual(normalize_approval('codex', raw)['action'], {'kind': 'tool'})

    def test_unknown_mcp_and_malformed_known_tools_are_complete_json(self):
        for tool, fields in [('mcp__pages__edit', {'command': 'content, not shell', 'description': 'write this', 'metadata': {'image': 'keep'}}),
                             ('Bash', {'command': ['not a command']}),
                             ('Write', {'file_path': '/tmp/a', 'content': 42}),
                             ('Edit', {'file_path': '/tmp/a', 'old_string': 'a', 'new_string': 'b', 'replace_all': 'yes'})]:
            result = normalize_approval('claude', request(tool, fields)['approval'])
            self.assertEqual(result['input'], fields)
            self.assertEqual(result['action'], {'kind': 'tool'})
            self.assertNotIn('reason', result)

    def test_v2_choices_are_explicit_exact_and_retried_by_id(self):
        broker = InteractionBroker()
        self.addCleanup(broker.close)
        pending = broker._publish(request(), 60)
        self.assertEqual(broker.pending(content_version=1)['requests'], [])
        self.assertEqual(len(broker.pending(content_version=2)['requests'][0]['responseOptions']), 3)
        base = dict(generation=broker.generation, requestID=pending.public['requestID'], version=1, idempotencyKey='retry')
        for payload in [dict(base, action='allowOnce'), dict(base, action='choose', optionID='invented')]:
            with self.assertRaises(BrokerError):
                broker.submit(payload)
        payload = dict(base, action='choose', optionID='session')
        receipt = broker.submit(payload)
        self.assertEqual(broker.submit(payload), receipt)
        self.assertEqual(pending.response, {'action': 'choose', 'optionID': 'session'})
        with self.assertRaises(BrokerError):
            broker.submit(dict(payload, optionID='once'))

    def test_no_choices_means_no_remote_approval_and_oversize_input_is_rejected_not_cut(self):
        broker = InteractionBroker()
        self.addCleanup(broker.close)
        pending = broker._publish(request(choices=[]), 60)
        self.assertEqual(pending.public['responseOptions'], [])
        for value in [request(input={'command': 'x' * 65536}), request(choices=[{'id': 'same', 'label': 'A'}, {'id': 'same', 'label': 'B'}])]:
            with self.assertRaises(BrokerError):
                broker._publish(value, 60)
        with self.assertRaises(ValueError):
            normalize_approval('codex', {'toolName': 'MCP', 'input': {'n': float('nan')}})


if __name__ == '__main__':
    unittest.main()
