#!/usr/bin/env python3
"""Forward Codex lifecycle events to Paceman.

Adapted from Omarchy Watch for Codex under MIT; see CODEX_HOOK_UPSTREAM.md and
OMARCHY_WATCH_CODEX_LICENSE beside this file.
"""

import json
import fcntl
import hashlib
import os
from pathlib import Path
import socket
import sys
import time


EVENTS = {
    "UserPromptSubmit": "working",
    "Stop": "completed",
    "Interrupt": "interrupted",
    "SessionEnd": "ended",
}


def socket_path() -> Path:
    root = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    return root / "omarchy-watch.sock"


def transition(state: dict, payload: dict) -> str | None:
    """Track opaque call IDs; never infer approval decisions from tool output."""
    hook = payload.get("hook_event_name")
    turn = str(payload.get("turn_id", ""))
    if hook in EVENTS:
        if hook == "Stop" and state.get("turn", turn) != turn:
            return None
        state.clear()
        if hook == "UserPromptSubmit":
            state.update(turn=turn, active={}, waiting=[], unmatched=False)
        return EVENTS[hook]
    if state.get("turn") != turn:
        if state:
            return None
        state.clear()
        state.update(turn=turn, active={}, waiting=[], unmatched=False)
    active = state["active"]
    waiting = set(state["waiting"])
    was_waiting = bool(waiting or state["unmatched"])
    tool = payload.get("tool_name")
    call = payload.get("tool_use_id")
    if hook == "PreToolUse" and isinstance(call, str) and call:
        active[call] = tool
        if tool in ("request_user_input", "request_user_input_async"):
            waiting.add(call)
    elif hook == "PermissionRequest":
        # PermissionRequest has no documented tool_use_id. If several calls
        # of the same tool overlap, keep attention until all candidates finish.
        candidates = {key for key, name in active.items() if name == tool}
        waiting.update(candidates)
        if not candidates:
            # Missing/untrusted PreToolUse: alert anyway and clear on lifecycle
            # end rather than guessing that an unrelated call resolved it.
            state["unmatched"] = True
    elif hook == "PostToolUse" and isinstance(call, str):
        started_tool = active.pop(call, None)
        # An async question returns before the user answers it. Keep attention
        # until a new prompt or terminal turn event clears the session.
        if started_tool != "request_user_input_async":
            waiting.discard(call)
    state["waiting"] = sorted(waiting)
    is_waiting = bool(waiting or state["unmatched"])
    if hook == "PreToolUse" and tool == "request_user_input_async":
        return "needs-input"
    if is_waiting and not was_waiting:
        return "needs-input"
    if was_waiting and not is_waiting:
        return "working"
    return None


def process(payload: dict, session: str) -> None:
    # Serialize state changes AND delivery so concurrent hooks cannot send a
    # stale working event after a newer permission request. Runtime-only data
    # contains IDs/tool names, never command arguments or responses.
    root = socket_path().parent / "paceman-codex"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    key = hashlib.sha256(session.encode()).hexdigest()
    path = root / (key + ".json")
    with open(root / (key + ".lock"), "a", opener=private_open) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            state = json.loads(path.read_text())
        except (FileNotFoundError, ValueError):
            state = {}
        event = transition(state, payload)
        if state:
            with open(path, "w", opener=private_open) as output:
                json.dump(state, output)
        else:
            path.unlink(missing_ok=True)
        if event:
            command = {
                "command": "agent-event", "source": "codex",
                "adapter": "paceman",
                "session": session, "turn": str(payload.get("turn_id", "")),
                "event": event, "timestamp": int(time.time()),
            }
            if payload.get("hook_event_name") == "UserPromptSubmit":
                command["hook"] = "UserPromptSubmit"
            if (payload.get("hook_event_name") == "PreToolUse"
                    and payload.get("tool_name") == "request_user_input_async"):
                command["attention"] = "async"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.1)
                client.connect(str(socket_path()))
                client.sendall((json.dumps(command) + "\n").encode())
                client.recv(4096)


def private_open(path, flags):
    return os.open(path, flags, 0o600)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            print("{}")
            return
        session = str(payload.get("session_id", ""))
        if session and payload.get("hook_event_name") in {
            *EVENTS, "PreToolUse", "PermissionRequest", "PostToolUse",
        }:
            process(payload, session)
    except (BrokenPipeError, ConnectionError, OSError, TypeError, ValueError,
            json.JSONDecodeError):
        # Paceman availability must never affect a Codex turn.
        pass
    print("{}")


if __name__ == "__main__":
    main()
