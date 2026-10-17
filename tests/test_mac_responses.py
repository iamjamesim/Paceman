import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from macos import control, install, responses, uninstall


class ResponseSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'agents.json').write_text(json.dumps({'providers': ['codex', 'claude']}))
        self.paths = {p: self.root / f'{p}.json' for p in ('codex', 'claude')}
        self.enterContext(patch.object(responses, 'hook_path', side_effect=lambda p, **_: self.paths[p]))

    def test_opt_in_preserves_observers_foreign_hooks_and_trust_definitions(self):
        original = {'custom': 'keep', 'hooks': {'PermissionRequest': [
            {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': '/bin/echo foreign'}]},
            {'hooks': [{'type': 'command', 'command': "python3 observer.py", 'timeout': 3}]}]}}
        for path in self.paths.values():
            path.write_text(json.dumps(original))
        before = copy.deepcopy(original)
        self.assertFalse(responses.enabled(self.root))
        changes = responses.configure(self.root, sys.executable, True)
        self.assertTrue(responses.enabled(self.root))
        self.assertEqual(len(changes), 3)
        for provider, path in self.paths.items():
            value = json.loads(path.read_text())
            self.assertEqual(value['custom'], 'keep')
            self.assertEqual(value['hooks']['PermissionRequest'][:2], before['hooks']['PermissionRequest'])
            hook = value['hooks']['PermissionRequest'][-1]['hooks'][0]
            self.assertEqual(shlex.split(hook['command']), [sys.executable, '-B',
                str(self.root / 'lib/macos/interaction_hook.py'), '--provider', provider])
            self.assertEqual(hook['timeout'], 605)
            self.assertNotIn('async', hook)
            question_hook = value['hooks']['PreToolUse'][-1]['hooks'][0]
            self.assertEqual(question_hook['timeout'], hook['timeout'])
            self.assertNotIn('async', question_hook)
            if provider == 'claude':
                self.assertEqual(value['hooks']['PreToolUse'][-1]['matcher'], '^AskUserQuestion$')
            else:
                self.assertEqual(value['hooks']['PreToolUse'][-1]['matcher'], '^request_user_input(_async)?$')
        mtimes = {p: path.stat().st_mtime_ns for p, path in self.paths.items()}
        self.assertEqual(responses.configure(self.root, sys.executable, True), [])
        self.assertEqual(mtimes, {p: path.stat().st_mtime_ns for p, path in self.paths.items()})
        responses.configure(self.root, sys.executable, False)
        self.assertFalse(responses.enabled(self.root))
        for path in self.paths.values():
            value = json.loads(path.read_text())
            self.assertEqual(value['hooks']['PermissionRequest'], original['hooks']['PermissionRequest'])

    def test_validate_all_before_changing_any_agent(self):
        self.paths['codex'].write_text('{}')
        self.paths['claude'].write_text('{broken')
        with self.assertRaises(ValueError):
            responses.configure(self.root, sys.executable, True)
        self.assertEqual(self.paths['codex'].read_text(), '{}')
        self.assertFalse(responses.enabled(self.root))
        self.paths['claude'].write_text('{"disableAllHooks":true}')
        with self.assertRaisesRegex(ValueError, 'disableAllHooks'):
            responses.configure(self.root, sys.executable, True)
        self.assertEqual(self.paths['codex'].read_text(), '{}')

    def test_failed_write_restores_prior_files(self):
        for path in self.paths.values():
            path.write_text('{}')
        write = responses._write
        calls = []
        def fail_second(path, data, mode=0o600):
            calls.append(path)
            if len(calls) == 2:
                raise OSError('disk failure')
            return write(path, data, mode)
        with patch.object(responses, '_write', side_effect=fail_second):
            with self.assertRaises(OSError):
                responses.configure(self.root, sys.executable, True)
        self.assertEqual([p.read_text() for p in self.paths.values()], ['{}', '{}'])
        self.assertFalse(responses.enabled(self.root))

    def test_provider_removal_and_uninstall_remove_only_owned_responses(self):
        responses.configure(self.root, sys.executable, True)
        (self.root / 'agents.json').write_text(json.dumps({'providers': ['codex']}))
        responses.configure(self.root, sys.executable, True)
        self.assertFalse(json.loads(self.paths['claude'].read_text())['hooks']['PermissionRequest'])
        path = self.paths['codex']
        value = json.loads(path.read_text())
        value['hooks']['PermissionRequest'][0]['hooks'].append({'type': 'command', 'command': '/bin/echo keep'})
        path.write_text(json.dumps(value))
        with patch.object(uninstall, 'ROOT', self.root):
            cleaned = uninstall.cleaned_hooks(path)
        self.assertEqual(cleaned['hooks']['PermissionRequest'], [{'hooks': [
            {'type': 'command', 'command': '/bin/echo keep'}]}])

    def test_symbolic_link_settings_or_marker_are_not_replaced(self):
        target = self.root / 'real-config'
        target.write_text('{}')
        self.paths['codex'].symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'ownership'):
            responses.configure(self.root, sys.executable, True)
        self.assertEqual(target.read_text(), '{}')
        self.paths['codex'].unlink()
        (self.root / 'responses-enabled').symlink_to(target)
        self.assertFalse(responses.enabled(self.root))
        with self.assertRaisesRegex(ValueError, 'symbolic link'):
            responses.configure(self.root, sys.executable, True)
        self.assertFalse(self.paths['codex'].exists())

    def test_restart_failure_rolls_back_hook_definitions_and_setting(self):
        with patch.object(control, 'ROOT', self.root), \
                patch.object(sys, 'argv', ['pacemanctl', 'responses-on']), \
                patch.object(control, 'launch', side_effect=subprocess.CalledProcessError(1, 'launchctl')), \
                patch.object(sys, 'stderr'):
            with self.assertRaises(SystemExit):
                control.main()
        self.assertFalse(responses.enabled(self.root))
        self.assertFalse(any(path.exists() for path in self.paths.values()))

    def test_sharing_paused_stays_paused_when_enabling(self):
        (self.root / 'sharing-paused').write_text('paused\n')
        with patch.object(control, 'ROOT', self.root), \
                patch.object(sys, 'argv', ['pacemanctl', 'responses-on']), \
                patch.object(control, 'launch') as launch, patch('builtins.print'):
            control.main()
        launch.assert_not_called()
        self.assertTrue(responses.enabled(self.root))
        self.assertTrue((self.root / 'sharing-paused').exists())

    def test_install_preserves_opt_in_for_new_selected_provider_and_repeats_without_changes(self):
        (self.root / 'responses-enabled').write_text('enabled\n')
        with patch.object(install, 'ROOT', self.root), patch.object(install, 'PYTHON', sys.executable):
            for provider, path in self.paths.items():
                install.install_hooks(path, provider=provider)
                document = json.loads(path.read_text())
                matching = [h for g in document['hooks']['PermissionRequest'] for h in g['hooks']
                            if responses.owns_hook(h, self.root, provider)]
                self.assertEqual(len(matching), 1)
                self.assertEqual(install.install_hooks(path, provider=provider), [])
