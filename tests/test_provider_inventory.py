"""Finite installed-producer inventories must map to explicit classifications."""
import importlib.util
import json
from pathlib import Path
import unittest

from service.codex_attention import classify_request, HUMAN_DYNAMIC_TOOLS

SESSION = 'native-thread'


class ProviderInventoryTests(unittest.TestCase):
    def test_extracted_producer_and_ui_inventory_has_no_unclassified_known_cases(self):
        root = Path(__file__).resolve().parents[1]
        inventory = json.loads((root / 'tests/fixtures/codex-desktop-inventory.json').read_text())
        public = json.loads((root / 'tests/fixtures/codex-appserver-inventory.json').read_text())
        for method in public['methods']:
            if method != 'item/tool/call':
                self.assertIn(classify_request(SESSION, dict(method=method,
                    params=dict(threadId=SESSION, turnId='turn'))), ('human', 'internal'), method)
        for method in set(inventory['producer_methods']) | set(inventory['ui_methods']):
            if method == 'item/tool/call':
                continue  # Its finite human subset is checked separately below.
            raw = dict(id=1, method=method, params=dict(threadId=SESSION, turnId='turn'))
            self.assertIn(classify_request(SESSION, raw), ('human', 'internal'), method)
        self.assertEqual(set(inventory['dynamic_tools']), HUMAN_DYNAMIC_TOOLS)
        self.assertEqual(set(inventory['mcp_modes']), {'form', 'url', 'openai/form', 'openaiForm', 'openai/userVerification'})
        self.assertEqual(set(inventory['ui_item_types']), {'agentMessage', 'fileChange', 'planImplementation', 'userInputResponse'})
        spec = importlib.util.spec_from_file_location('inventory_check', root / 'scripts/check-codex-desktop-inventory.py')
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        changed = {key: set(inventory[key]) for key in ('producer_methods', 'ui_methods', 'dynamic_tools', 'mcp_modes', 'ui_item_types')}
        changed['ui_methods'].add('new/requestInput')
        with self.assertRaisesRegex(ValueError, 're-audit coverage'):
            checker.check_sets(changed, inventory)

    def test_claude_control_originators_match_the_native_human_predicate(self):
        from service.claude_attention import classify_request as classify_claude, HUMAN_SUBTYPES, INTERNAL_AGENT_SUBTYPES, CLIENT_SUBTYPES
        inventory = json.loads((Path(__file__).parent / 'fixtures/claude-control-inventory.json').read_text())
        self.assertEqual(set(inventory['human_subtypes']), HUMAN_SUBTYPES)
        self.assertEqual(set(inventory['control_subtypes']), HUMAN_SUBTYPES | INTERNAL_AGENT_SUBTYPES | CLIENT_SUBTYPES)
        human = {'can_use_tool': dict(tool_name='Bash', input={}),
                 'request_user_dialog': dict(dialog_kind='native'),
                 'elicitation': dict(mcp_server_name='server', message='Choose')}
        for subtype in inventory['control_subtypes']:
            frame = dict(type='control_request', request_id=subtype,
                         request=dict(subtype=subtype, **human.get(subtype, {})))
            self.assertEqual(classify_claude(frame), 'human' if subtype in HUMAN_SUBTYPES else 'internal', subtype)
        self.assertEqual(classify_claude({'request': {'subtype': 'future_request'}}), 'unknown')
