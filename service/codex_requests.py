"""Translate Codex's typed requests without interpreting arbitrary tool JSON.

Incoming IDs and decision objects stay adapter-local. Public option IDs are
opaque handles to the exact offered decision, never reconstructed permissions.
"""
from copy import deepcopy
import hashlib
import json
import shlex
import time
import uuid
from service.interaction_content import codex_terminal_input


def session_key(session):
    return hashlib.sha256(("codex:" + session).encode()).hexdigest()


def is_browser_approval(request):
    params = request.get('params')
    meta = params.get('_meta') if isinstance(params, dict) else None
    return (request.get('method') == 'mcpServer/elicitation/request' and isinstance(meta, dict)
            and meta.get('tool_name') == 'access_browser_origin' and meta.get('connector_id') == 'browser-use')


def decode_async_question(session, turn, item, index, question):
    """The desktop answers async questions through native turn steering.

    This is its own question-reply envelope, not a hook denial/tool-result
    override. Async questions retain the desktop's ordinary answer/edit semantics.
    """
    if (not isinstance(question, dict) or set(question) - {"title", "options"}
            or not isinstance(question.get("title"), str)):
        return None
    options = question.get("options") or []
    if not isinstance(options, list) or any(not isinstance(o, str) for o in options):
        return None
    qid = json.dumps(["request_user_input_async", item, index], separators=(",", ":"), ensure_ascii=False)
    public = dict(provider="codex", sessionID=session_key(session), kind="question", title="Answer Codex", detail="",
        questions=[dict(id="answer", prompt=question["title"], multiple=False,
                        options=[dict(label=o, description="") for o in options])])

    def answer(response):
        if response["action"] != "answer":
            return None
        value = response["answers"]["answer"]
        text = "\n".join([*(options[i] for i in value["selected"]), *([value["text"]] if value["text"].strip() else [])])
        reply = [dict(questionItemId=qid, question=question["title"], answer=text)]
        content = "<send_user_message_question_reply>\n" + json.dumps(reply, ensure_ascii=False) + "\n</send_user_message_question_reply>"
        message_id = "paceman-" + str(uuid.uuid4())
        # The desktop owner reads restoreMessage before submitting turn/steer,
        # and keeps it with the optimistic message for matching and recovery.
        # Inherit its cwd and collaboration mode rather than changing either.
        restore = dict(id=message_id, text=content, cwd=None, createdAt=int(time.time() * 1000),
                       context=dict(prompt=content, turnTrigger="send_user_message_async_question",
                                    addedFiles=[], fileAttachments=[], imageAttachments=[],
                                    commentAttachments=[], ideContext=None, workspaceRoots=[]))
        return "thread-follower-steer-turn", dict(input=[dict(type="text", text=content, text_elements=[])],
                                                  clientUserMessageId=message_id, restoreMessage=restore)
    return public, answer


def decode_request(session, request, items=(), *, browser_global_allowed=None):
    method, params = request.get("method"), request.get("params")
    if not isinstance(params, dict) or params.get("threadId") != session:
        return None
    base = dict(provider="codex", sessionID=session_key(session), detail="")
    if method == "mcpServer/elicitation/request":
        return _mcp_approval(base, params, browser_global_allowed=browser_global_allowed)
    if method == "item/tool/requestUserInput":
        questions = params.get("questions")
        if not isinstance(questions, list) or not questions or len(questions) > 4:
            return None
        normalized = []
        ids = set()
        for q in questions:
            if (not isinstance(q, dict) or q.get("isSecret") is not False
                    or type(q.get("isOther")) is not bool or not isinstance(q.get("id"), str)
                    or q["id"] in ids or not isinstance(q.get("question"), str)):
                # Secret entry needs its own secure input profile.
                return None
            ids.add(q["id"])
            options = q.get("options")
            if options is not None and (not isinstance(options, list) or any(
                    not isinstance(o, dict) or not isinstance(o.get("label"), str)
                    or not isinstance(o.get("description"), str) for o in options)):
                return None
            normalized.append(dict(id=q["id"], prompt=q["question"], multiple=False,
                                   options=deepcopy(options or []), allowsText=q["isOther"]))
            if not q["isOther"] and not options:
                return None
        constrained = any(not q["allowsText"] for q in normalized)
        if not constrained:
            for q in normalized:
                del q["allowsText"]
        public = dict(base, kind="question", title="Answer questions", questions=normalized)
        if constrained:
            public["contentVersion"] = 3

        def answer(response):
            if response["action"] != "answer":
                return None
            result = {}
            for q in normalized:
                a = response["answers"][q["id"]]
                values = [q["options"][i]["label"] for i in a["selected"]]
                if a["text"].strip():
                    values.append(a["text"])
                result[q["id"]] = {"answers": values}
            return ("thread-follower-submit-user-input", {"response": {"answers": result}})
        return public, answer

    if method not in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
        return None
    tool = "commandExecution" if method == "item/commandExecution/requestApproval" else "fileChange"
    terminal = None
    if tool == "commandExecution" and params.get("kind", "command") != "command":
        terminal = codex_terminal_input(params)
        if terminal is None:
            return None
        tool = "write_stdin"
    original = deepcopy(params)
    if tool == "fileChange":
        item = next((i for i in items if i.get("id") == params.get("itemId")
                     and i.get("type") == "fileChange"), None)
        if item is None or not item.get("changes"):
            return None  # Never offer a blind approval with no patch to review.
        original["changes"] = deepcopy(item["changes"])
    decisions = params.get("availableDecisions")
    if terminal and decisions is None:
        return None
    if decisions is None:
        # These are the protocol's legacy decision sets, not guessed labels
        # extracted from the command or a permission description.
        decisions = ["accept", "acceptForSession", "decline", "cancel"]
    if not isinstance(decisions, list) or not decisions or len(decisions) > 16:
        return None
    choices, mapped = [], {}
    labels = {"accept": "Allow once", "acceptForSession": "Allow for this session",
              "decline": "Decline", "cancel": "Cancel this turn"}
    for i, decision in enumerate(decisions):
        confirmation = None
        label = labels.get(decision) if isinstance(decision, str) else None
        if isinstance(decision, dict) and set(decision) == {"acceptWithExecpolicyAmendment"}:
            amendment = decision["acceptWithExecpolicyAmendment"]
            prefix = amendment.get("execpolicy_amendment") if isinstance(amendment, dict) else None
            if (isinstance(amendment, dict) and set(amendment) == {"execpolicy_amendment"} and isinstance(prefix, list)
                    and prefix and all(isinstance(p, str) for p in prefix)):
                label = "Always allow commands starting with: " + json.dumps(prefix, ensure_ascii=False)
                if len(label) > 512:
                    label = "Always allow this command prefix"
                    confirmation = "Allow future commands starting with these exact arguments:\n\n" + shlex.join(prefix)
        if isinstance(decision, dict) and set(decision) == {"applyNetworkPolicyAmendment"}:
            amendment = decision["applyNetworkPolicyAmendment"]
            rule = amendment.get("network_policy_amendment") if isinstance(amendment, dict) else None
            if (isinstance(rule, dict) and set(rule) == {"host", "action"}
                    and isinstance(rule["host"], str) and rule["action"] in ("allow", "deny")):
                label = ("Always allow connections to " if rule["action"] == "allow"
                         else "Always deny connections to ") + rule["host"]
        if label is None or len(label) > 512:
            # Policy-writing variants need their own explicit scope UI. Do not
            # quietly turn them into a broad Allow button or drop the choice.
            return None
        key = f"decision-{i}"
        mapped[key] = deepcopy(decision)
        choices.append(dict(id=key, label=label, **({"confirmation": confirmation} if confirmation else {})))
    approval = dict(toolName=tool, input=original, inputKind="approvalRequest")
    if terminal:
        parent = next((i for i in items if i.get("type") == "commandExecution"
                       and i.get("id") == params.get("itemId")
                       and str(i.get("processId")) == str(terminal["session_id"])
                       and isinstance(i.get("command"), str)), None)
        if parent:
            approval["terminalContext"] = dict(sessionID=terminal["session_id"], command=parent["command"])
    if isinstance(params.get("cwd"), str):
        approval["workingDirectory"] = params["cwd"]
    if isinstance(params.get("reason"), str):
        approval["reason"] = params["reason"]
    public = dict(base, kind="approval", title=f"Allow {tool}?", contentVersion=2,
                  approval=approval, responseOptions=choices)
    if any('confirmation' in option for option in choices):
        public['contentVersion'] = 4

    def answer(response):
        if response["action"] != "choose" or response["optionID"] not in mapped:
            return None
        target = ("thread-follower-command-approval-decision" if tool in ("commandExecution", "write_stdin")
                  else "thread-follower-file-approval-decision")
        return target, {"decision": mapped[response["optionID"]]}
    return public, answer


def _mcp_approval(base, params, *, browser_global_allowed=None):
    """Desktop's typed MCP approval metadata, not arbitrary MCP form input."""
    meta, schema = params.get("_meta"), params.get("requestedSchema")
    if (params.get("mode") != "form" or not isinstance(meta, dict)
            or meta.get("codex_approval_kind") != "mcp_tool_call"
            or not isinstance(meta.get("tool_params"), dict)
            or not isinstance(meta.get("tool_name"), str)
            or not isinstance(params.get("serverName"), str)
            or meta.get("codex_request_type", "approval_request") != "approval_request"
            or not isinstance(schema, dict) or schema.get("properties") != {}
            or schema.get("required", []) or schema.get("type") != "object"):
        return None
    tool, original = meta["tool_name"], meta["tool_params"]
    browser = tool == 'access_browser_origin' and meta.get('connector_id') == 'browser-use'
    if ((tool in ('access_browser_origin', 'access_browser_origin_with_raw_cdp') and not browser)
            or 'plan_token' in original or 'confirmation_summary' in original):
        return None
    persist = meta.get("persist", [])
    persist = [persist] if isinstance(persist, str) else persist
    if not isinstance(persist, list) or any(p not in ("session", "always") for p in persist):
        return None
    options = [("once", "Allow once", None)]
    if browser:
        origin = meta.get('origin', original.get('origin'))
        if not isinstance(origin, str) or not origin.strip() or len(origin) > 4096 or 'always' not in persist:
            return None
        options.append(('always', 'Always allow this site', 'always'))
        if browser_global_allowed is True:
            options.append(('browser-all-sites', 'Allow for all sites', 'all-sites'))
    else:
        for scope in dict.fromkeys(persist):
            options.append((scope, "Allow for this session" if scope == "session" else "Always allow this tool", scope))
    options.append(("decline", "Decline", None))
    canonical_tool = tool if tool.startswith("mcp__") else f"mcp__{params['serverName']}__{tool}"
    approval = dict(toolName=canonical_tool, input=deepcopy(original))
    if isinstance(meta.get("subtitle"), str):
        approval["reason"] = meta["subtitle"]
    if meta.get("riskLevel") == "high":
        approval["reason"] = "Elevated risk. " + approval.get("reason", "")
    display = meta.get("tool_params_display")
    if browser:
        display = [dict(name='origin', display_name='Website', value=origin)]
    if display is not None:
        if not isinstance(display, list) or any(not isinstance(f, dict)
                or not isinstance(f.get("name"), str) or "value" not in f
                or "display_name" in f and not isinstance(f["display_name"], str) for f in display):
            return None
        approval["displayText"] = "\n\n".join(
            f.get("display_name", f["name"]) + ":\n" + (f["value"] if isinstance(f["value"], str)
            else json.dumps(f["value"], ensure_ascii=False, indent=2, allow_nan=False)) for f in display)
    title = params.get("message")
    public = dict(base, kind="approval", title=title if isinstance(title, str) and 0 < len(title) <= 256 else f"Allow {tool}?",
                  contentVersion=2, approval=approval,
                  responseOptions=[dict(id=i, label=label) for i, label, _ in options])
    if browser_global_allowed is True and browser:
        public['contentVersion'] = 4
        next(o for o in public['responseOptions'] if o['id'] == 'browser-all-sites')['confirmation'] = (
            'Allow the browser to access all websites without asking again, including sites beyond this request.')
    mapped = {i: scope for i, _, scope in options}

    def answer(response):
        option = response.get("optionID")
        if response["action"] != "choose" or option not in mapped:
            return None
        action = "decline" if option == "decline" else "accept"
        metadata = {'persist': mapped[option]} if mapped[option] else None
        if option == 'browser-all-sites':
            metadata = dict(persist='always', browser_use_persistent_approval_scope='all-sites')
        result = dict(action=action, content={} if action == "accept" else None, _meta=metadata)
        return "thread-follower-submit-mcp-server-elicitation-response", {"response": result}
    return public, answer
