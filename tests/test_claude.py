import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from macos.claude_hook import message_for
from service.hub import Store
from service.macos import MacSource
from service.push import live_notification
from service.status import DesktopStatus


class ClaudeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.store = Store(self.root / 'hub.sqlite3')
        self.clock = 10.0
        self.source = self.enterContext(MacSource(self.store, socket_path=self.root / 'hook.sock',
            allowance_reader=lambda: None, turn_status_reader=lambda _: {}, monotonic=lambda: self.clock))
        self.source.next_allowance_at = float('inf')

    def hook(self, hook, *, session='one', turn='prompt-1', **fields):
        data = dict(hook_event_name=hook, session_id=session, prompt_id=turn, **fields)
        message = message_for(data)
        if message:
            self.source.receive(message)
        return message

    def tick(self, seconds=6):
        self.clock += seconds
        self.source.tick()

    def test_same_session_id_does_not_overwrite_other_provider(self):
        self.source.receive(dict(command='agent-event', session='one', turn='prompt-1',
                                 event='working', hook='UserPromptSubmit'))
        self.hook('UserPromptSubmit')
        sessions = self.store.snapshot()['sessions']
        self.assertEqual({s['provider'] for s in sessions}, {'codex', 'claude'})
        self.assertEqual(len({s['id'] for s in sessions}), 2)
        self.hook('Stop')
        states = {s['provider']: s['state'] for s in self.store.snapshot()['sessions']}
        self.assertEqual(states, {'codex': 'working', 'claude': 'finished'})
        self.assertEqual(len(self.source.turn_ids), 1)  # Claude never enters Codex's status reader.
        self.hook('SessionEnd')
        self.assertEqual([s['provider'] for s in self.store.snapshot()['sessions']], ['codex'])

    def test_prompt_attention_resume_finish_and_new_prompt(self):
        self.hook('SessionStart', turn='')
        self.assertEqual(self.store.snapshot()['state'], 'idle')
        self.hook('UserPromptSubmit')
        self.hook('PreToolUse', tool_name='AskUserQuestion', tool_use_id='ask-1')
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.tick()
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.hook('PostToolUse', tool_name='Read', tool_use_id='read-1')
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.hook('PostToolUse', tool_name='AskUserQuestion', tool_use_id='ask-1')
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.hook('Stop')
        self.assertEqual(self.store.snapshot()['state'], 'finished')
        self.hook('PermissionRequest', tool_name='Bash')
        self.hook('PostToolUse', tool_name='Bash')
        self.tick()
        self.assertEqual(self.store.snapshot()['state'], 'finished')
        self.hook('UserPromptSubmit', turn='prompt-2')
        self.hook('Stop', turn='prompt-1')
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_short_question_and_parallel_permissions(self):
        self.hook('UserPromptSubmit')
        self.hook('PreToolUse', tool_name='AskUserQuestion', tool_use_id='q')
        revision = self.store.snapshot()['revision']
        self.hook('PostToolUse', tool_name='AskUserQuestion', tool_use_id='q')
        self.tick()
        self.assertEqual(self.store.snapshot()['revision'], revision)
        for id in ('a', 'b'):
            self.hook('PreToolUse', tool_name='Bash', tool_use_id=id)
        self.hook('PermissionRequest', tool_name='Bash')
        self.hook('PostToolUse', tool_name='Bash', tool_use_id='a')
        self.tick()
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.hook('PostToolUseFailure', tool_name='Bash', tool_use_id='b')
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_api_failure_and_stop_hook_continuation(self):
        self.hook('UserPromptSubmit')
        self.hook('StopFailure', error='rate_limit', error_details='private')
        self.assertEqual(self.store.snapshot()['state'], 'failed')
        self.hook('Stop')
        self.assertEqual(self.store.snapshot()['state'], 'failed')
        self.hook('UserPromptSubmit', turn='prompt-2')
        self.hook('Stop', turn='prompt-2')
        self.hook('PreToolUse', turn='prompt-2', tool_name='Read', tool_use_id='r')
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.hook('PostToolUseFailure', turn='prompt-2', tool_name='Read',
                  tool_use_id='r', is_interrupt=True)
        self.assertEqual(self.store.snapshot()['state'], 'idle')

    def test_elicitation_is_scoped_and_cleared_on_turn_end(self):
        self.hook('UserPromptSubmit')
        self.hook('Elicitation', elicitation_id='first')
        self.hook('Elicitation', elicitation_id='second')
        self.tick()
        self.hook('ElicitationResult', elicitation_id='first')
        self.assertEqual(self.store.snapshot()['state'], 'needs_input')
        self.hook('ElicitationResult', elicitation_id='second')
        self.assertEqual(self.store.snapshot()['state'], 'working')
        self.hook('Elicitation', elicitation_id='first')
        self.hook('Stop')
        self.tick()
        self.assertEqual(self.store.snapshot()['state'], 'finished')

    def test_no_timeout_invents_a_completion(self):
        self.hook('UserPromptSubmit')
        self.tick(86400)
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_subagents_and_unscoped_callbacks_are_ignored(self):
        self.hook('UserPromptSubmit')
        self.assertIsNone(self.hook('Stop', agent_id='child'))
        self.assertIsNone(self.hook('SubagentStop'))
        self.assertIsNone(self.hook('Stop', turn=''))
        for invalid in (None, [], 1, {'hook_event_name': []}):
            self.assertIsNone(message_for(invalid))
        self.assertEqual(self.store.snapshot()['state'], 'working')

    def test_real_adapter_socket_and_privacy(self):
        project = self.root / 'project'
        project.mkdir()
        payload = dict(hook_event_name='UserPromptSubmit', session_id='private-session',
            prompt_id='private-prompt-id', cwd=str(project), prompt='PRIVATE PROMPT',
            transcript_path='/PRIVATE TRANSCRIPT', tool_input={'command': 'PRIVATE COMMAND'})
        result = subprocess.run([sys.executable, 'macos/claude_hook.py'], input=json.dumps(payload),
            env={**os.environ, 'PACEMAN_HOOK_SOCKET': str(self.root / 'hook.sock')},
            capture_output=True, text=True, check=True)
        self.assertEqual((result.stdout, result.stderr), ('', ''))
        snapshot = self.store.snapshot()
        self.assertEqual(snapshot['sessions'][0]['provider'], 'claude')
        content = live_notification(snapshot, time.time())[0]['aps']['content-state']
        self.assertEqual(content['providers'], ['claude'])
        self.assertEqual(content['workspaceLabel'], 'project')
        with self.store.connect() as db:
            saved = str([tuple(r) for r in db.execute('SELECT * FROM events')])
        for secret in ('PRIVATE', 'private-session', 'private-prompt-id', str(self.root)):
            self.assertNotIn(secret, saved)
        DesktopStatus(self.root / 'status.json', self.store).publish(self.source, force=True)
        status = json.loads((self.root / 'status.json').read_text())
        self.assertEqual(status['providers'], ['claude'])
        self.assertGreater(status['lastAgentEventByProvider']['claude'], 0)

    def test_adapter_failure_never_blocks_claude(self):
        for payload in ('garbage', '[]', json.dumps(dict(hook_event_name='Stop',
                session_id='session', prompt_id='prompt'))):
            result = subprocess.run([sys.executable, 'macos/claude_hook.py'], input=payload,
                env={**os.environ, 'PACEMAN_HOOK_SOCKET': str(self.root / 'missing.sock')},
                capture_output=True, text=True, timeout=3)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))


if __name__ == '__main__':
    unittest.main()
