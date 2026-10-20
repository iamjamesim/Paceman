"""Decode native Claude control requests; decisions retain native request IDs."""
from copy import deepcopy
from service.interactions import BrokerError, _request


def choices(data):
    result = [("once", "Allow once", {"behavior": "allow"})]
    suggestions = data.get("permission_suggestions", [])
    if not isinstance(suggestions, list):
        return None
    for index, suggestion in enumerate(suggestions):
        if not isinstance(suggestion, dict):
            return None
        destination = suggestion.get("destination")
        scope = {"session": "this session", "localSettings": "this project (local settings)",
                 "projectSettings": "this project's shared settings", "userSettings": "all your projects"}.get(destination)
        if scope is None:
            return None
        if suggestion.get("type") == "addRules" and suggestion.get("behavior") == "allow":
            if set(suggestion) != {"type", "behavior", "rules", "destination"}:
                return None
            rules = suggestion.get("rules")
            if not isinstance(rules, list) or not rules or any(
                    not isinstance(r, dict) or not isinstance(r.get("toolName"), str)
                    or set(r) - {"toolName", "ruleContent"}
                    or "ruleContent" in r and not isinstance(r["ruleContent"], str) for r in rules):
                return None
            rule = "; ".join(r["toolName"] + (" matching " + r["ruleContent"] if "ruleContent" in r else " (all uses)") for r in rules)
            label = f"Allow {rule} for {scope}"
        elif suggestion.get("type") == "setMode" and suggestion.get("mode") == "acceptEdits" and destination == "session":
            if set(suggestion) != {"type", "mode", "destination"}:
                return None
            label = "Allow file edits for this session"
        else:
            return None
        if len(label) > 512:
            return None
        result.append((f"suggestion-{index}", label, {"behavior": "allow", "updatedPermissions": [deepcopy(suggestion)]}))
    result.append(("decline", "Decline", {"behavior": "deny"}))
    return result


def decode_request(session, frame):
    """Return review content and a native response encoder, without hook routing.

    The caller authenticates the worker envelope. Unsupported interactive
    disclosures stay native, rather than becoming blind Allow/Deny buttons.
    """
    if (not isinstance(frame, dict) or frame.get('type') != 'control_request'
            or not isinstance(frame.get('request_id'), str)
            or not isinstance(frame.get('request'), dict)):
        return None
    data = frame['request']
    if data.get('subtype') != 'can_use_tool':
        return None
    tool, payload = data.get('tool_name'), data.get('input')
    if not isinstance(tool, str) or not isinstance(payload, dict) or data.get('agent_id'):
        return None
    if tool != 'AskUserQuestion' and data.get('requires_user_interaction'):
        return None
    if tool == 'ExitPlanMode':
        return None
    public = dict(provider='claude', sessionID=session, detail='')
    if tool == 'AskUserQuestion':
        questions = question_content(payload)
        if questions is None:
            return None
        public.update(kind='question', title='Answer Claude', questions=questions)
    else:
        offered = choices(data)
        if offered is None:
            return None
        if data.get('suppress_always_allow_rule'):
            offered = [o for o in offered if 'updatedPermissions' not in o[2]]
        approval = dict(toolName=tool, input=deepcopy(payload))
        reason = data.get('decision_reason') or data.get('description')
        if isinstance(reason, str):
            approval['reason'] = reason
        public.update(kind='approval', title=f'Allow {tool}?', contentVersion=2,
                      approval=approval, responseOptions=[dict(id=i, label=label) for i, label, _ in offered])
    try:
        _request(public)
    except (BrokerError, ValueError, TypeError, RecursionError):
        return None

    def encode(reply):
        if reply.get('action') == 'release':
            return None  # Relinquish only Paceman's view; never decide natively.
        if public['kind'] == 'question':
            decision = question_answer(payload, public, reply)
        else:
            decision = next((deepcopy(d) for i, _, d in offered
                             if reply.get('action') == 'choose' and i == reply.get('optionID')), None)
        if decision is None:
            return None
        if decision['behavior'] == 'allow':
            # Echo unchanged input for native versions that require this field.
            decision.setdefault('updatedInput', deepcopy(payload))
        else:
            decision['message'] = 'User declined this request in Paceman.'
        return dict(type='control_response', response=dict(subtype='success',
                    request_id=frame['request_id'], response=decision))
    return public, encode


def question_content(payload):
    questions = payload.get('questions')
    if not isinstance(questions, list) or not 1 <= len(questions) <= 4:
        return None
    normalized, prompts = [], set()
    for i, q in enumerate(questions):
        if (not isinstance(q, dict) or set(q) - {'question', 'header', 'options', 'multiSelect'}
                or not isinstance(q.get('question'), str) or q['question'] in prompts
                or type(q.get('multiSelect', False)) is not bool or not isinstance(q.get('options'), list)):
            return None
        prompts.add(q['question'])
        options = []
        for option in q['options']:
            if not isinstance(option, dict) or set(option) - {'label', 'description'}:
                return None
            options.append(dict(label=option.get('label'), description=option.get('description', '')))
        normalized.append(dict(id=f'q{i}', prompt=q['question'], multiple=q.get('multiSelect', False), options=options))
    return normalized


def question_answer(original, request, reply):
    answers = reply.get('answers')
    if (reply.get('action') != 'answer' or not isinstance(answers, dict)
            or set(answers) != {q['id'] for q in request['questions']}):
        return None
    native = {}
    for q in request['questions']:
        answer = answers[q['id']]
        if not isinstance(answer, dict):
            return None
        selected, text = answer.get('selected'), answer.get('text')
        if (not isinstance(selected, list) or not isinstance(text, str) or len(text) > 4096
                or any(type(i) is not int or not 0 <= i < len(q['options']) for i in selected)
                or len(set(selected)) != len(selected) or not q['multiple'] and len(selected) > 1
                or not selected and not text.strip()):
            return None
        parts = [q['options'][i]['label'] for i in selected]
        if text.strip():
            parts.append(text)
        native[q['prompt']] = ', '.join(parts)
    return dict(behavior='allow', updatedInput={**deepcopy(original), 'answers': native})
