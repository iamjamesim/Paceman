"""Attention observed in the verified desktop stream, independent of replies.

This is bounded to the inspected stream-v11 producer. Unknown tool execution
is not a human prompt. Request identities stay in RAM beside their native owner.
"""
from service.native_attention import PendingDecisions


# Producer inventory: Codex 26.1013.40934 (20770), desktop stream 11.
# The transport dispatcher handles INTERNAL_METHODS before pending-array insertion.
HUMAN_METHODS = frozenset({'item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
    'item/permissions/requestApproval', 'item/tool/requestUserInput',
    'item/tool/requestOptionPicker', 'mcpServer/elicitation/request', 'item/plan/requestImplementation'})
INTERNAL_METHODS = frozenset({'currentTime/read', 'account/chatgptAuthTokens/refresh',
    'attestation/generate', 'item/tool/requestSetupCodexContextPicker', 'applyPatchApproval', 'execCommandApproval'})
HUMAN_DYNAMIC_TOOLS = frozenset({'request_environment_input', 'request_onboarding_input',
    'request_option_picker', 'setup_codex_step'})


def _text(value, limit=None):
    return isinstance(value, str) and (limit is None or 0 < len(value.strip()) <= limit)


def _options(value):
    return isinstance(value, list) and all(isinstance(o, dict) and _text(o.get('label'))
        and (o.get('description') is None or isinstance(o['description'], str)) for o in value)


def _dynamic_input(params):
    if params.get('namespace') not in (None, 'codex_app'):
        return False
    tool, args = params.get('tool'), params.get('arguments')
    if not isinstance(tool, str) or tool not in HUMAN_DYNAMIC_TOOLS or not isinstance(args, dict):
        return False
    if tool == 'setup_codex_step':
        return set(args) == {'step'} and args['step'] in ('role', 'task')
    if tool == 'request_option_picker':
        return (_text(args.get('question')) and _options(args.get('options'))
            and ('allowMultiple' not in args or type(args['allowMultiple']) is bool)
            and all(args.get(k) is None or isinstance(args[k], str) for k in ('submitLabel', 'skipLabel')))
    if tool == 'request_onboarding_input':
        questions = args.get('questions')
        return (set(args) == {'questions'} and isinstance(questions, list) and 1 <= len(questions) <= 3
            and all(isinstance(q, dict) and not set(q) - {'id', 'header', 'question', 'options'}
                and _text(q.get('id')) and _text(q.get('question'))
                and (q.get('header') is None or isinstance(q['header'], str))
                and _options(q.get('options')) and len(q['options']) >= 2 for q in questions))
    if tool == 'request_environment_input':
        if args.get('mode') not in ('repositories', 'name', 'secrets', 'network', 'review'):
            return False
        if 'reason' in args and not _text(args['reason'], 512):
            return False
        for key, count, size in (('domains', 20, 253), ('repositories', 10, 512)):
            if key in args and (not isinstance(args[key], list) or len(args[key]) > count
                               or any(not _text(v, size) for v in args[key])):
                return False
        return ('secrets' not in args or isinstance(args['secrets'], list) and len(args['secrets']) <= 20
            and all(isinstance(s, dict) and _text(s.get('name'), 128) for s in args['secrets']))
    return False


def classify_request(session, request):
    """Classify entries retained by the desktop, not arbitrary transport calls.

    Unknown methods stay diagnostic; their presence is not evidence of a human
    prompt. Ordinary dynamic tools use the producer's execution path instead.
    """
    params, method = request.get('params'), request.get('method')
    if (request.get('completed') is True or not isinstance(params, dict)
            or params.get('threadId') != session or not isinstance(method, str)):
        return 'invalid'
    if method in INTERNAL_METHODS:
        return 'internal'
    turn = params.get('turnId')
    if turn is not None and not isinstance(turn, str):
        return 'invalid'
    if method == 'item/tool/call':
        # BS dispatches only these tools as human input; its fallback executes
        # ordinary tools without inserting them in conversationState.requests.
        return 'human' if turn and _dynamic_input(params) else 'internal'
    if method in HUMAN_METHODS:
        # The desktop explicitly renders session-level MCP forms/URL requests.
        return 'human' if turn or method == 'mcpServer/elicitation/request' else 'invalid'
    return 'unknown'


def human_request(session, request):
    return classify_request(session, request) == 'human'
