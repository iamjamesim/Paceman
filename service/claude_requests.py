"""Claude permission-stage decisions; never preempt native PreToolUse UI."""
from copy import deepcopy
import hashlib
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


def normalize(provider, data):
    if (provider != "claude" or not isinstance(data, dict) or data.get("agent_id")
            or data.get("hook_event_name") != "PermissionRequest"):
        return None
    session, tool, payload = (data.get(k) for k in ("session_id", "tool_name", "tool_input"))
    if (not isinstance(session, str) or not 1 <= len(session) <= 512
            or not isinstance(tool, str) or not isinstance(payload, dict)):
        return None
    request = dict(provider="claude", sessionID=hashlib.sha256(f"claude:{session}".encode()).hexdigest(), detail="")
    if tool == "AskUserQuestion":
        questions = payload.get("questions")
        if not isinstance(questions, list) or not 1 <= len(questions) <= 4:
            return None
        normalized, prompts = [], set()
        for i, q in enumerate(questions):
            if (not isinstance(q, dict) or set(q) - {"question", "header", "options", "multiSelect"}
                    or not isinstance(q.get("question"), str) or q["question"] in prompts
                    or type(q.get("multiSelect")) is not bool or not isinstance(q.get("options"), list)):
                return None
            prompts.add(q["question"])
            options = []
            for option in q["options"]:
                if not isinstance(option, dict) or set(option) - {"label", "description"}:
                    return None
                options.append(dict(label=option.get("label"), description=option.get("description", "")))
            normalized.append(dict(id=f"q{i}", prompt=q["question"], multiple=q["multiSelect"], options=options))
        request.update(kind="question", title="Answer Claude", questions=normalized)
    elif tool == "ExitPlanMode":
        return None
    else:
        options = choices(data)
        if options is None:
            return None
        approval = dict(toolName=tool, input=deepcopy(payload))
        if isinstance(data.get("cwd"), str):
            approval["workingDirectory"] = data["cwd"]
        request.update(kind="approval", title=f"Allow {tool}?", contentVersion=2,
                       approval=approval, responseOptions=[dict(id=i, label=label) for i, label, _ in options])
    try:
        _request(request)
    except (BrokerError, ValueError, TypeError, RecursionError):
        return None
    return request


def native_response(provider, original, request, reply):
    if provider != "claude" or not isinstance(reply, dict):
        return None
    if request["kind"] == "approval":
        if reply.get("action") != "choose":
            return None
        decision = next((deepcopy(d) for i, _, d in choices(original) or [] if i == reply.get("optionID")), None)
        if decision is None:
            return None
    else:
        answers = reply.get("answers")
        if (reply.get("action") != "answer" or not isinstance(answers, dict)
                or set(answers) != {q["id"] for q in request["questions"]}):
            return None
        native = {}
        for q in request["questions"]:
            answer = answers[q["id"]]
            if not isinstance(answer, dict):
                return None
            selected, text = answer.get("selected"), answer.get("text")
            if (not isinstance(selected, list) or not isinstance(text, str) or len(text) > 4096
                    or any(type(i) is not int or not 0 <= i < len(q["options"]) for i in selected)
                    or len(set(selected)) != len(selected) or not q["multiple"] and len(selected) > 1
                    or not selected and not text.strip()):
                return None
            parts = [q["options"][i]["label"] for i in selected]
            if text.strip():
                parts.append(text)
            native[q["prompt"]] = ", ".join(parts)
        decision = dict(behavior="allow", updatedInput={**deepcopy(original["tool_input"]), "answers": native})
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}
