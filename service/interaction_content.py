"""Decode provider tool input once, at the desktop boundary.

Only documented built-in schemas are interpreted. MCP arguments and unfamiliar
extensions remain complete JSON; field names alone never identify display data.
"""
from copy import deepcopy
import json


def _json_value(value):
    if type(value) is dict:
        return all(type(key) is str and _json_value(item) for key, item in value.items())
    if type(value) is list:
        return all(_json_value(item) for item in value)
    return value is None or type(value) in (str, int, float, bool)


def normalize_approval(provider, value):
    if not isinstance(value, dict) or set(value) - {"toolName", "workingDirectory", "reason", "input", "terminalContext"}:
        raise ValueError("invalid approval")
    tool = value.get("toolName")
    if not isinstance(tool, str) or not tool.strip() or len(tool) > 256 or "input" not in value:
        raise ValueError("invalid approval")
    for name in ("workingDirectory", "reason"):
        if name in value and (not isinstance(value[name], str) or len(value[name]) > 4096):
            raise ValueError("invalid approval")
    # Reject non-JSON values and non-finite numbers, never truncate an action.
    if not _json_value(value["input"]):
        raise ValueError("invalid JSON input")
    encoded = json.dumps(value["input"], allow_nan=False, ensure_ascii=False, indent=2)
    if len(encoded.encode()) > 32768:
        raise ValueError("approval input too large")
    result = dict(deepcopy(value), action={"kind": "tool"}, inputJSON=encoded, hasAdditionalInput=False)
    original = result.pop("input")
    fields = original if isinstance(original, dict) else {}
    consumed = set()
    action = result["action"]
    context = result.pop("terminalContext", None)
    if context is not None and (not isinstance(context, dict)
            or set(context) != {"sessionID", "command"}
            or type(context["sessionID"]) is not int or not isinstance(context["command"], str)
            or not context["command"].strip() or len(context["command"]) > 16384
            or context["sessionID"] != fields.get("session_id") or tool != "write_stdin" or provider != "codex"):
        raise ValueError("invalid terminal context")
    # Codex's documented approval payload adds parent_call_id and permission
    # metadata to these native tool arguments. Preserve that complete input.
    if (provider == "codex" and tool == "write_stdin"
            and type(fields.get("session_id")) is int and -(2**31) <= fields["session_id"] < 2**31
            and isinstance(fields.get("chars", ""), str)):
        text = fields.get("chars", "")
        operation = "poll" if not text else "interrupt" if set(text) == {"\x03"} else "write"
        action.update(kind="terminalInput", text=text, terminalSessionID=str(fields["session_id"]), operation=operation)
        if context is not None:
            action["parentCommand"] = context["command"]
        consumed = {"session_id", "chars"}
    elif (tool in {"codex": ("Bash", "PowerShell", "apply_patch"), "claude": ("Bash",)}.get(provider, ())
            and isinstance(fields.get("command"), str) and fields["command"].strip()):
        action.update(kind="patch" if tool == "apply_patch" else "command", text=fields["command"])
        consumed.add("command")
        if isinstance(fields.get("description"), str):
            if not result.get("reason") and fields["description"].strip():
                result["reason"] = fields["description"]
            consumed.add("description")
        elif fields.get("description", False) is None:
            consumed.add("description")
    elif (provider == "claude" and tool == "Write"
            and isinstance(fields.get("file_path"), str) and fields["file_path"]
            and isinstance(fields.get("content"), str)):
        action.update(kind="fileWrite", filePath=fields["file_path"], text=fields["content"])
        consumed = {"file_path", "content"}
    elif (provider == "claude" and tool == "Edit"
            and isinstance(fields.get("file_path"), str) and fields["file_path"]
            and all(isinstance(fields.get(k), str) for k in ("old_string", "new_string"))
            and ("replace_all" not in fields or type(fields["replace_all"]) is bool)):
        action.update(kind="fileEdit", filePath=fields["file_path"],
                      before=fields["old_string"], text=fields["new_string"],
                      replaceAll=fields.get("replace_all", False))
        consumed = {"file_path", "old_string", "new_string", "replace_all"}
    result["hasAdditionalInput"] = bool(consumed and fields.keys() - consumed)
    return result
