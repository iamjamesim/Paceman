import json
from pathlib import Path
import plistlib
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch

from macos import agents, control, install, responses, uninstall


class ResponseSetupTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (self.root / 'agents.json').write_text(json.dumps({'providers': ['codex', 'claude']}))
        library = self.root / 'lib/macos'
        library.mkdir(parents=True)
        for name in ('codex_hook.py', 'claude_hook.py', 'interaction_hook.py'):
            (library / name).touch()
        self.paths = {p: self.root / f'{p}.json' for p in ('codex', 'claude')}
        for module in (agents, control):
            self.enterContext(patch.object(module, 'hook_path', side_effect=lambda p, **_: self.paths[p]))
        self.enterContext(patch.multiple(install, ROOT=self.root, PYTHON=sys.executable))
        self.enterContext(patch.multiple(control, ROOT=self.root, PLIST=self.root / 'source.plist'))
        self.enterContext(patch.object(uninstall, 'ROOT', self.root))

    def test_normal_setup_includes_responses_for_each_selected_agent(self):
        for provider, path in self.paths.items():
            with self.subTest(provider=provider):
                install.install_hooks(path, provider=provider)
                document = json.loads(path.read_text())
                for event in ('PreToolUse', 'PermissionRequest'):
                    matches = [item for group in document['hooks'][event] for item in group['hooks']
                               if responses.owns_hook(item, self.root, provider)]
                    self.assertEqual(len(matches), 1)
                    self.assertEqual(shlex.split(matches[0]['command']), [sys.executable, '-B',
                        str(self.root / 'lib/macos/interaction_hook.py'), '--provider', provider])
                    self.assertEqual(matches[0]['timeout'], 605)
                    self.assertNotIn('async', matches[0])
                self.assertEqual(control.missing_hooks(provider=provider), [])

    def test_reinstall_preserves_foreign_hooks_and_usable_reviewed_commands(self):
        foreign = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': '/bin/echo foreign'}]}
        next_python = self.root / 'new python'
        next_python.symlink_to(sys.executable)
        for provider, path in self.paths.items():
            path.write_text(json.dumps({'keep': True, 'hooks': {'PermissionRequest': [foreign]}}))
            install.install_hooks(path, provider=provider)
            before, modified = path.read_bytes(), path.stat().st_mtime_ns
            with patch.object(install, 'PYTHON', str(next_python)):
                self.assertEqual(install.install_hooks(path, provider=provider), [])
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(path.stat().st_mtime_ns, modified)
            self.assertEqual(json.loads(before)['hooks']['PermissionRequest'][0], foreign)

    def test_missing_or_disabled_response_hooks_require_setup_repair(self):
        for provider, path in self.paths.items():
            with self.subTest(provider=provider):
                install.install_hooks(path, provider=provider)
                document = json.loads(path.read_text())
                document['hooks']['PermissionRequest'] = [group for group in document['hooks']['PermissionRequest']
                    if not any(responses.owns_hook(item, self.root, provider) for item in group['hooks'])]
                document['hooks']['PreToolUse'][-1]['hooks'][0]['async'] = True
                path.write_text(json.dumps(document))
                self.assertEqual(set(control.missing_hooks(provider=provider)), {'PermissionRequest', 'PreToolUse'})
                self.assertEqual(set(install.install_hooks(path, provider=provider)), {'PermissionRequest', 'PreToolUse'})
                self.assertEqual(control.missing_hooks(provider=provider), [])

    def test_agent_removal_removes_both_hook_types_and_preserves_other_handlers(self):
        control.configure_agents(['codex', 'claude'])
        path = self.paths['claude']
        document = json.loads(path.read_text())
        foreign = {'type': 'command', 'command': '/bin/echo keep'}
        document['hooks']['PermissionRequest'][-1]['hooks'].append(foreign)
        path.write_text(json.dumps(document))
        with patch.object(control, 'launch') as launch:
            control.configure_agents(['codex'])
            launch.assert_not_called()
        cleaned = json.loads(path.read_text())
        self.assertEqual(cleaned['hooks']['PermissionRequest'], [{'hooks': [foreign]}])
        self.assertTrue(all(not groups for event, groups in cleaned['hooks'].items() if event != 'PermissionRequest'))
        self.assertEqual(control.missing_hooks(provider='codex'), [])

    def test_global_hook_disable_is_preserved_and_reported(self):
        for provider, path in self.paths.items():
            path.write_text('{"disableAllHooks":true}')
            install.install_hooks(path, provider=provider)
            self.assertTrue(json.loads(path.read_text())['disableAllHooks'])
            self.assertTrue(control.missing_hooks(provider=provider))

    def test_setup_status_and_instructions_show_the_actual_response_command(self):
        plist = self.root / 'source.plist'
        plist.write_bytes(plistlib.dumps({'ProgramArguments': ['/app/background', '/different/python', str(self.root)]}))
        for provider, path in self.paths.items():
            install.install_hooks(path, provider=provider)
        result = control.status()
        for provider in self.paths:
            expected = responses.command(self.root, sys.executable, provider)
            self.assertEqual(result['responseHookCommands'][provider], expected)
            with patch('builtins.print') as output:
                install.print_response_review_steps(provider)
            output.assert_any_call('     ' + expected)
