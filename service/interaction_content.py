"""Decode provider tool input once, at the desktop boundary.

Only documented built-in schemas are interpreted. MCP arguments and unfamiliar
extensions remain complete JSON; field names alone never identify display data.
"""
from copy import deepcopy
import json


def normalize_approval(provider, value):
    if not isinstance(value, dict) or set(value) - {"toolName", "workingDirectory", "reason", "input"}:
        raise ValueError("invalid approval")
    tool = value.get("toolName")
    if not isinstance(tool, str) or not tool.strip() or len(tool) > 256 or "input" not in value:
        raise ValueError("invalid approval")
    for name in ("workingDirectory", "reason"):
        if name in value and (not isinstance(value[name], str) or len(value[name]) > 4096):
            raise ValueError("invalid approval")
    # Reject non-JSON values and non-finite numbers, never truncate an action.
    encoded = json.dumps(value["input"], allow_nan=False, ensure_ascii=False)
    if len(encoded.encode()) > 32768:
        raise ValueError("approval input too large")
    result = dict(deepcopy(value), action={"kind": "tool"}, hasAdditionalInput=False)
    fields = result["input"] if isinstance(result["input"], dict) else {}
    consumed = set()
    action = result["action"]
    if (tool in ("Bash", "PowerShell", "apply_patch")
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
