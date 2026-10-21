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
    def test_typed_command_prefix_is_bounded_and_never_downgraded(self):
        prefix = ['git', '', "a b", "quote'argument", '日本語']
        raw = request(choices=[dict(id='prefix', label='Always approve', commandPrefix=prefix)])
        raw['contentVersion'] = 5
        broker = InteractionBroker()
        self.addCleanup(broker.close)
        handle = broker.publish_live(raw)
        self.assertEqual(handle.public['responseOptions'][0]['commandPrefix'], prefix)
        for version in range(1, 5):
            self.assertEqual(broker.pending(content_version=version)['requests'], [])
        self.assertEqual(len(broker.pending(content_version=5)['requests']), 1)
        for invalid in ([], [''], ['  '], ['git', 3], ['git', 'bad\x00argument'], ['git'] * 257):
            broken = dict(raw, responseOptions=[dict(id='prefix', label='Always approve', commandPrefix=invalid)])
            with self.subTest(invalid=repr(invalid)[:80]), self.assertRaises(BrokerError):
                broker.publish_live(broken)
        for version in (1, 2, 3, 4):
            with self.subTest(version=version), self.assertRaises(BrokerError):
                broker.publish_live(dict(raw, contentVersion=version))
        raw['responseOptions'][0]['confirmation'] = 'Another required scope'
        with self.assertRaises(BrokerError):
            broker.publish_live(raw)
        del raw['responseOptions'][0]['confirmation']
        raw['approval']['toolName'] = 'UnknownTool'
        with self.assertRaises(BrokerError):
            broker.publish_live(raw)

    def test_provider_preview_is_never_promoted_to_a_complete_command(self):
        result = normalize_approval('claude', dict(toolName='Bash', inputKind='providerPreview', input={'command': 'rm …'}))
        self.assertEqual(result['action'], {'kind': 'tool'})
        self.assertEqual(result['inputKind'], 'providerPreview')
        with self.assertRaises(ValueError):
            normalize_approval('codex', dict(toolName='Bash', inputKind='guessed', input={}))

    def test_native_terminal_writes_distinguish_interrupt_poll_and_arbitrary_input(self):
        for text, operation in [("\x03\x03", "interrupt"), ("", "poll"), ("echo ready\n", "write"),
                                ("a\x03", "write"), (r'\u0003', "write"), ("\x03\n", "write")]:
            raw = request('write_stdin', {'session_id': 35467, 'chars': text,
                'parent_call_id': 'exact-parent', 'approval_id': 'exact-approval'})['approval']
            result = normalize_approval('codex', raw)
            self.assertEqual(result['action']['kind'], 'terminalInput')
            self.assertEqual(result['action']['operation'], operation)
            self.assertEqual(result['action']['text'], text)
            self.assertEqual(result['action']['terminalSessionID'], '35467')
            self.assertEqual(json.loads(result['inputJSON']), raw['input'])
            self.assertTrue(result['hasAdditionalInput'])
            self.assertNotIn('parentCommand', result['action'])
            self.assertEqual(normalize_approval('claude', raw)['action']['kind'], 'tool')
        for session in [False, '35467', 35467.5]:
            raw = request('write_stdin', {'session_id': session, 'chars': '\x03'})['approval']
            self.assertEqual(normalize_approval('codex', raw)['action']['kind'], 'tool')

    def test_terminal_parent_command_requires_matching_confirmed_context(self):
        raw = request('write_stdin', {'session_id': 35467, 'chars': '\x03'})['approval']
        raw['terminalContext'] = {'sessionID': 35467, 'command': 'xcodebuild test'}
        result = normalize_approval('codex', raw)
        self.assertEqual(result['action']['parentCommand'], 'xcodebuild test')
        raw['terminalContext']['sessionID'] = 99
        with self.assertRaises(ValueError):
            normalize_approval('codex', raw)

    def test_documented_commands_and_files_decode_at_source_and_preserve_extensions(self):
        for provider in ('codex', 'claude'):
            for tool in (('Bash', 'PowerShell', 'apply_patch') if provider == 'codex' else ('Bash',)):
                raw = request(tool)['approval']
                result = normalize_approval(provider, raw)
                self.assertEqual(json.loads(result['inputJSON']), raw['input'])
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
            self.assertEqual(json.loads(result['inputJSON']), fields)
            self.assertTrue(result['hasAdditionalInput'])
            self.assertEqual(normalize_approval('codex', raw)['action'], {'kind': 'tool'})

    def test_unknown_mcp_and_malformed_known_tools_are_complete_json(self):
        for tool, fields in [('mcp__pages__edit', {'command': 'content, not shell', 'description': 'write this', 'metadata': {'image': 'keep'}}),
                             ('Bash', {'command': ['not a command']}),
                             ('Write', {'file_path': '/tmp/a', 'content': 42}),
                             ('Edit', {'file_path': '/tmp/a', 'old_string': 'a', 'new_string': 'b', 'replace_all': 'yes'})]:
            result = normalize_approval('claude', request(tool, fields)['approval'])
            self.assertEqual(json.loads(result['inputJSON']), fields)
            self.assertEqual(result['action'], {'kind': 'tool'})
            self.assertNotIn('reason', result)

    def test_tool_names_are_scoped_to_their_provider_and_new_providers_stay_opaque(self):
        for provider, tool in [('claude', 'PowerShell'), ('claude', 'apply_patch'),
                               ('next-agent', 'Bash'), ('next-agent', 'Write')]:
            with self.subTest(provider=provider, tool=tool):
                raw = request(tool)['approval']
                result = normalize_approval(provider, raw)
                self.assertEqual(result['action'], {'kind': 'tool'})
                self.assertEqual(json.loads(result['inputJSON']), raw['input'])
                self.assertNotIn('reason', result)
        broker = InteractionBroker(provider_enabled=lambda provider: provider == 'next-agent')
        self.addCleanup(broker.close)
        pending = broker._publish(dict(request(), provider='next-agent'), 60)
        self.assertEqual(pending.public['provider'], 'next-agent')
        self.assertEqual(pending.public['approval']['action'], {'kind': 'tool'})
        with self.assertRaises(BrokerError):
            broker._publish(request(), 60)
        with self.assertRaises(BrokerError):
            broker._publish(dict(request(), provider='not an identifier'), 60)

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

    def test_opaque_input_does_not_depend_on_a_client_number_type_or_coerce_non_json_values(self):
        original = {'integer': 12345678901234567890123456789012345678901234567890,
                    'magnitude': 1e300, 'nested': [True, None, '日本語\n\x03']}
        broker = InteractionBroker()
        self.addCleanup(broker.close)
        pending = broker._publish(request('mcp__other__tool', original), 60)
        payload = pending.public['approval']
        self.assertEqual(json.loads(payload['inputJSON']), original)
        self.assertIn(str(original['integer']), payload['inputJSON'])
        self.assertIn('1e+300', payload['inputJSON'])
        self.assertNotIn('input', payload)
        for invalid in [{1: 'coerced key'}, {'tuple': (1, 2)}, {'set': {1, 2}}]:
            with self.assertRaises(ValueError):
                normalize_approval('next-agent', request(input=invalid)['approval'])

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
