import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

from macos import agents, control, install, responses, uninstall
from service import hub


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

    def test_agent_server_does_not_start_or_advertise_the_retired_response_bridge(self):
        with patch.object(hub, 'Server') as server_factory, \
             patch('service.macos.MacSource'), \
             patch('builtins.print'), \
             patch('service.interactions.ResponseListener') as listener, \
             patch('service.interactions.InteractionBroker') as broker, \
             patch.object(sys, 'argv', ['hub', '--data-dir', str(self.root / 'data'), 'serve', '--source', 'macos']):
            server = server_factory.return_value.__enter__.return_value
            server.interactions = None
            hub.main()
            self.assertIsNone(server.interactions)
            listener.assert_not_called()
            broker.assert_not_called()

    def test_agent_sources_cannot_opt_back_into_the_blocking_bridge(self):
        for provider in ('macos', 'omarchy'):
            with self.subTest(provider=provider), \
                 patch.object(sys, 'argv', ['hub', 'serve', '--source', provider,
                     '--interaction-socket', str(self.root / 'legacy.sock')]), \
                 patch('sys.stderr'), self.assertRaises(SystemExit) as error:
                hub.main()
            self.assertEqual(error.exception.code, 2)

    def test_normal_setup_installs_only_observers_for_each_selected_agent(self):
        for provider, path in self.paths.items():
            with self.subTest(provider=provider):
                install.install_hooks(path, provider=provider)
                document = json.loads(path.read_text())
                self.assertFalse(any(responses.owns_hook(item, self.root, provider)
                    for groups in document['hooks'].values() for group in groups for item in group['hooks']))
                self.assertEqual(control.missing_hooks(provider=provider), [])

    def test_upgrade_removes_legacy_responders_preserving_shared_groups_and_reviewed_observers(self):
        for provider, path in self.paths.items():
            with self.subTest(provider=provider):
                install.install_hooks(path, provider=provider)
                document = json.loads(path.read_text())
                observers = {event: groups[0] for event, groups in document['hooks'].items()}
                foreign = {'type': 'command', 'command': '/bin/echo keep'}
                for event in ('PermissionRequest', 'PreToolUse', 'Stop'):
                    document['hooks'][event].append({'matcher': 'original', 'hooks': [foreign,
                        {'type': 'command', 'command': responses.command(self.root, '/retired/python', provider),
                         'timeout': 605}]})
                path.write_text(json.dumps(document))
                self.assertEqual(set(install.install_hooks(path, provider=provider)),
                                 {'PermissionRequest', 'PreToolUse', 'Stop'})
                result = json.loads(path.read_text())
                for event, group in observers.items():
                    self.assertEqual(result['hooks'][event][0], group)
                for event in ('PermissionRequest', 'PreToolUse', 'Stop'):
                    self.assertEqual(result['hooks'][event][-1], {'matcher': 'original', 'hooks': [foreign]})
                self.assertEqual(install.install_hooks(path, provider=provider), [])
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

    def test_missing_or_disabled_observers_still_require_setup_repair(self):
        for provider, path in self.paths.items():
            with self.subTest(provider=provider):
                install.install_hooks(path, provider=provider)
                document = json.loads(path.read_text())
                document['hooks']['PermissionRequest'] = []
                document['hooks']['PreToolUse'][0]['hooks'][0]['async'] = True
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
        document['hooks']['PermissionRequest'].append({'hooks': [{'type': 'command',
            'command': responses.command(self.root, sys.executable, 'claude'), 'timeout': 605}]})
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

    def test_setup_status_and_instructions_offer_only_activity_commands(self):
        plist = self.root / 'source.plist'
        plist.write_bytes(plistlib.dumps({'ProgramArguments': ['/app/background', sys.executable, str(self.root)]}))
        for provider, path in self.paths.items():
            install.install_hooks(path, provider=provider)
        result = control.status()
        self.assertNotIn('responseHookCommands', result)
        self.assertEqual(set(result['hookCommands']), set(self.paths))
        with patch('builtins.print') as output:
            install.print_hook_review_steps(self.root / 'pacemanctl')
        text = '\n'.join(str(call.args[0]) for call in output.call_args_list)
        self.assertIn('Questions and approvals stay in Codex', text)
        self.assertNotIn('interaction_hook.py', text)
