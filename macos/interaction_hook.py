#!/usr/bin/env python3
"""Opt-in synchronous input bridge. No configuration or monitoring changes.

No output means the provider should continue its native interaction. Hook input
and decisions are never logged; original question payloads stay in this process.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import sys

# Direct hooks run from the installed macos directory, outside the package root.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from service.interactions import RESPONSE_TIMEOUT_SECONDS


MAX_BYTES = 64 * 1024
TIMEOUT_SECONDS = RESPONSE_TIMEOUT_SECONDS


def _text(value, maximum, *, empty=False):
    return (isinstance(value, str) and len(value) <= maximum
            and (empty or bool(value.strip())) and "\x00" not in value)


def _json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def normalize(provider, data):
    """Return a display request without copying opaque hook metadata."""
    if provider not in ("codex", "claude") or not isinstance(data, dict):
        return None
    session = data.get("session_id")
    tool = data.get("tool_name")
    if not _text(session, 512) or not _text(tool, 240):
        return None
    event = data.get("hook_event_name")
    payload = data.get("tool_input")
    if not isinstance(payload, dict):
        return None
    request = {"provider": provider,
               "sessionID": hashlib.sha256(f"{provider}:{session}".encode()).hexdigest()}
    if event == "PermissionRequest" and tool != "AskUserQuestion":
        cwd = data.get("cwd")
        if not _text(cwd, 4096) or not os.path.isabs(cwd):
            return None
        request.update(kind="approval", title=f"Allow {tool}?",
                       detail=f"Tool: {tool}\nWorking directory: {cwd}\n\n{_json(payload)}",
                       questions=[])
        if len(request["detail"]) > 16384:
            return None
    elif event == "PreToolUse" and (provider == "claude" and tool == "AskUserQuestion"
            or provider == "codex" and tool in ("request_user_input", "request_user_input_async")):
        questions = payload.get("questions")
        if not isinstance(questions, list) or not 1 <= len(questions) <= 4:
            return None
        normalized = []
        prompts = set()
        for index, question in enumerate(questions):
            if not isinstance(question, dict):
                return None
            if provider == "codex":
                # Desktop async questions use title/string choices; the native
                # blocking tool uses question/id and label/description choices.
                prompt = question.get("title") if tool.endswith("_async") else question.get("question")
                options = question.get("options")
                if options is None:
                    options = []
                multiple = False
                if question.get("isSecret", False) is not False:
                    return None  # Secret input remains on the native surface.
                if tool == "request_user_input" and not _text(question.get("id"), 160):
                    return None
            else:
                prompt = question.get("question")
                options = question.get("options")
                multiple = question.get("multiSelect", False)
            if (not _text(prompt, 4096) or provider == "claude" and prompt in prompts
                    or type(multiple) is not bool or not isinstance(options, list)
                    or not (0 if provider == "codex" else 1) <= len(options) <= 16):
                return None
            prompts.add(prompt)
            normalized_options = []
            labels = set()
            for option in options:
                if provider == "codex" and tool.endswith("_async") and isinstance(option, str):
                    label, description = option, ""
                elif isinstance(option, dict):
                    label, description = option.get("label"), option.get("description", "")
                else:
                    return None
                if (not _text(label, 512) or label in labels
                        or not _text(description, 2048, empty=True)):
                    return None
                labels.add(label)
                normalized_options.append({"label": label, "description": description})
            normalized.append({"id": f"q{index}", "prompt": prompt,
                               "multiple": multiple, "options": normalized_options})
        if provider == "codex" and tool == "request_user_input":
            ids = [q["id"] for q in questions]
            if len(set(ids)) != len(ids):
                return None
        request.update(kind="question", title=f"Answer {'Codex' if provider == 'codex' else 'Claude'}",
                       detail="", questions=normalized)
    else:
        return None
    # The transport envelope also has to fit, without truncating action details.
    if len(_json({"request": request, "timeoutSeconds": TIMEOUT_SECONDS}).encode()) > MAX_BYTES:
        return None
    return request


def native_response(provider, original, request, reply):
    """Validate independently of the broker before emitting a native decision."""
    if not isinstance(reply, dict):
        return None
    action = reply.get("action")
    if request["kind"] == "approval":
        if action not in ("allowOnce", "deny"):
            return None
        decision = {"behavior": "allow" if action == "allowOnce" else "deny"}
        if action == "deny":
            decision["message"] = "Declined from Paceman."
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                       "decision": decision}}
    if provider not in ("codex", "claude") or action != "answer":
        return None
    answers = reply.get("answers")
    questions = request["questions"]
    if not isinstance(answers, dict) or set(answers) != {q["id"] for q in questions}:
        return None
    native_answers = {}
    for question in questions:
        answer = answers[question["id"]]
        if not isinstance(answer, dict) or set(answer) - {"selected", "text"}:
            return None
        selected, text = answer.get("selected", []), answer.get("text", "")
        if (not isinstance(selected, list) or not _text(text, 8192, empty=True)
                or any(type(i) is not int or not 0 <= i < len(question["options"])
                       for i in selected)
                or len(set(selected)) != len(selected)
                or (not question["multiple"] and len(selected) > 1)
                or not selected and not text.strip()):
            return None
        pieces = [question["options"][i]["label"] for i in selected]
        value = ", ".join(pieces)
        if text.strip():
            value = value + "\n" + text if value else text
        native_answers[question["id"] if provider == "codex" else question["prompt"]] = value
    if provider == "codex":
        original_questions = original["tool_input"]["questions"]
        mapped = {}
        for index, question in enumerate(questions):
            key = (original_questions[index]["id"] if original["tool_name"] == "request_user_input"
                   else question["id"])
            mapped[key] = {"question": question["prompt"], "answer": native_answers[question["id"]]}
        # Codex has no PreToolUse tool-result override. Its supported deny
        # feedback skips the question UI and delivers the user's actual answer
        # to this exact tool call. It never grants a tool permission.
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
            "permissionDecision": "deny", "permissionDecisionReason":
                "The user answered this question in Paceman. The question UI was skipped "
                "to avoid asking twice. Continue using these user answers:\n" + _json(mapped)}}
    updated = dict(original["tool_input"])
    updated["answers"] = native_answers
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                   "permissionDecision": "allow", "updatedInput": updated}}


def notify_answered(original):
    """Clear only this invocation's attention; send no question or answer text."""
    from macos.codex_hook import deliver
    turn, tool_id = original.get("turn_id"), original.get("tool_use_id")
    if not _text(turn, 160) or not _text(tool_id, 160):
        return
    path = os.environ.get("PACEMAN_HOOK_SOCKET") or str(
        Path.home() / "Library/Application Support/Paceman/hook.sock")
    deliver({"command": "agent-event", "session": original["session_id"],
             "turn": turn, "event": "question-answered", "toolID": tool_id,
             "hook": "PacemanQuestionAnswered"}, path, "PostToolUse")


def exchange(request):
    path = os.environ.get("PACEMAN_INTERACTION_SOCKET") or str(
        Path.home() / "Library/Application Support/Paceman/interaction.sock")
    message = (_json({"request": request, "timeoutSeconds": TIMEOUT_SECONDS}) + "\n").encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(TIMEOUT_SECONDS + 2)
        connection.connect(path)
        connection.sendall(message)
        with connection.makefile("rb") as stream:
            response = stream.readline(MAX_BYTES + 1)
        if len(response) > MAX_BYTES or not response.endswith(b"\n"):
            return None
        return json.loads(response)


def run(provider, input_stream, output_stream):
    try:
        raw = input_stream.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return
        original = json.loads(raw)
        request = normalize(provider, original)
        if request is None:
            return
        response = native_response(provider, original, request, exchange(request))
        if response is not None:
            encoded = _json(response)
            if len(encoded.encode()) <= MAX_BYTES:
                output_stream.write(encoded + "\n")
                output_stream.flush()
                if provider == "codex" and request["kind"] == "question":
                    notify_answered(original)
    except (OSError, ValueError, TypeError, KeyError, RecursionError, UnicodeError):
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("codex", "claude"))
    args = parser.parse_args()
    run(args.provider, sys.stdin.buffer, sys.stdout)


if __name__ == "__main__":
    main()
