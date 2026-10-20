"""Native permission competition must never reinstall PreToolUse interception."""
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from macos import interaction_hook as hook


class InteractionHookTests(unittest.TestCase):
    def test_legacy_invocations_never_read_payload_connect_or_return_a_decision(self):
        for provider in ("codex",):
            with self.subTest(provider=provider):
                output = io.StringIO()
                with patch("socket.socket", side_effect=AssertionError("Must not connect")):
                    hook.run(provider, object(), output)
                self.assertEqual(output.getvalue(), "")

    def test_claude_pretool_and_subagents_are_always_native(self):
        for extra in [dict(hook_event_name='PreToolUse'), dict(agent_id='child')]:
            payload = dict(hook_event_name='PermissionRequest', tool_name='AskUserQuestion',
                session_id='test', tool_input={}, **({} if 'hook_event_name' in extra else extra))
            payload.update(extra)
            output = io.StringIO()
            with patch('macos.interaction_hook.exchange', side_effect=AssertionError('Must not wait')):
                hook.run('claude', io.BytesIO(json.dumps(payload).encode()), output)
            self.assertEqual(output.getvalue(), '')

    def test_permission_stage_question_preserves_complete_original_batch(self):
        payload = dict(hook_event_name='PermissionRequest', tool_name='AskUserQuestion', session_id='test',
            tool_input=dict(questions=[dict(question=f'Which {i}?', header='Choice', multiSelect=False,
                options=[dict(label='First', description='Detail'), dict(label='Second', description='Detail')]) for i in range(2)],
                metadata={'preserve': True}))
        request = hook.normalize('claude', payload)
        self.assertIsNotNone(request)
        result = hook.native_response('claude', payload, request, dict(action='answer', answers={
            'q0': dict(selected=[0], text=''), 'q1': dict(selected=[], text='Custom')}))
        output = result['hookSpecificOutput']
        self.assertEqual(output['hookEventName'], 'PermissionRequest')
        self.assertEqual(output['decision']['updatedInput']['questions'], payload['tool_input']['questions'])
        self.assertEqual(output['decision']['updatedInput']['metadata'], {'preserve': True})
        self.assertEqual(output['decision']['updatedInput']['answers'], {'Which 0?': 'First', 'Which 1?': 'Custom'})

    def test_offered_permission_suggestions_keep_exact_scope_and_effect(self):
        suggestion = dict(type='addRules', rules=[dict(toolName='Bash', ruleContent='git status*')],
                          behavior='allow', destination='session')
        payload = dict(hook_event_name='PermissionRequest', tool_name='Bash', session_id='test',
            tool_input={'command': 'git status'}, permission_suggestions=[suggestion])
        request = hook.normalize('claude', payload)
        self.assertIn('this session', request['responseOptions'][1]['label'])
        reply = hook.native_response('claude', payload, request, dict(action='choose', optionID='suggestion-0'))
        self.assertEqual(reply['hookSpecificOutput']['decision']['updatedPermissions'], [suggestion])
        self.assertIsNone(hook.native_response('claude', payload, request, dict(action='choose', optionID='invented')))

    def test_cli_preserves_questions_approvals_and_all_native_choices(self):
        script = Path(__file__).resolve().parents[1] / "macos/interaction_hook.py"
        for provider in ("codex", "claude"):
            for event, tool in (("PreToolUse", "request_user_input"),
                                ("PreToolUse", "request_user_input_async"),
                                ("PreToolUse", "AskUserQuestion"),
                                ("PermissionRequest", "mcp__pages__edit")):
                payload = {"hook_event_name": event, "tool_name": tool,
                           "tool_input": {"questions": [{"question": "Which?",
                               "options": [str(i) for i in range(25)]}],
                               "large_input": "x" * 70000},
                           "permission_suggestions": [{"type": "addRules"}]}
                with self.subTest(provider=provider, event=event, tool=tool):
                    result = subprocess.run([sys.executable, str(script), "--provider", provider],
                        input=json.dumps(payload), capture_output=True, text=True, timeout=2)
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr, "")
