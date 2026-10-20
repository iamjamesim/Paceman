"""Private correlation where PermissionRequest omits tool_use_id.

Identical same-turn calls are indistinguishable in that hook API. After local
completion, conservatively leave that scope native for the rest of the turn.
Never clear a different question, tool input, session, or turn.
"""
import hashlib
import json


def binding(data):
    if not isinstance(data, dict):
        return None
    session, turn, tool, payload = (data.get(k) for k in ("session_id", "prompt_id", "tool_name", "tool_input"))
    if not isinstance(session, str) or not session:
        return None
    def digest(value):
        return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                        allow_nan=False, separators=(",", ":")).encode()).hexdigest()
    result = {"session": digest(["claude", session])}
    if not isinstance(turn, str) or not turn:
        return result
    result["turn"] = digest(["claude", session, turn])
    if isinstance(tool, str) and isinstance(payload, dict):
        if tool == "AskUserQuestion":
            payload = {k: v for k, v in payload.items() if k != "answers"}
        result["scope"] = digest(["claude", session, turn, tool, payload])
    return result
