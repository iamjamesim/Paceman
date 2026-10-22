#!/usr/bin/env python3
"""Small, non-blocking Codex lifecycle adapter; no prompts or transcript content."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import time
import unicodedata
import uuid


EVENTS = {
    "SessionStart": "started", "UserPromptSubmit": "working",
    "PermissionRequest": "needs-input", "PreToolUse": "needs-input",
    "PostToolUse": "working",
    "Stop": "completed", "Interrupt": "interrupted", "SessionEnd": "ended",
}
TERMINAL_HOOKS = {"Stop", "Interrupt", "SessionEnd"}
QUESTION_MATCHER = "^request_user_input(_async)?$"


def process_identity(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid=,comm="],
                            capture_output=True, text=True, check=True, timeout=.15)
    parent, executable = result.stdout.strip().split(None, 1)
    return int(parent), Path(executable)


def desktop_owned_runtime(*, reader=process_identity, pid=None):
    """Recognize only the Codex runtime directly owned by its desktop app.

    Inspect executable identities, never process arguments or conversation data.
    A bundled CLI launched by a terminal or an agent tool is not the app owner.
    """
    pid = os.getppid() if pid is None else pid
    visited = set()
    try:
        for _ in range(8):
            if pid <= 1 or pid in visited:
                return False
            visited.add(pid)
            parent, executable = reader(pid)
            if executable.name == "codex":
                _, owner = reader(parent)
                bundle = owner.parent.parent.parent
                info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                return (info.get("CFBundleIdentifier") == "com.openai.codex"
                        and owner == bundle / "Contents/MacOS" / info.get("CFBundleExecutable", "")
                        and executable.resolve().is_relative_to(bundle.resolve()))
            pid = parent
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError, plistlib.InvalidFileException):
        pass
    return False


def transient_desktop_fork(data):
    # An explicitly absent transcript means this fork has no saved history.
    # Missing fields and saved/user CLI forks must continue to be observed.
    return (data.get("hook_event_name") == "SessionStart" and data.get("source") == "fork"
            and "transcript_path" in data and data["transcript_path"] is None
            and sys.platform == "darwin" and desktop_owned_runtime())


def deliver(message, path, hook):
    """Require the source's receipt; briefly retry lifecycle-ending events."""
    deadline = time.monotonic() + (1.0 if hook in TERMINAL_HOOKS else 0.0)
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(.2 if hook in TERMINAL_HOOKS else .15)
                connection.connect(str(path))
                connection.sendall(json.dumps(message, separators=(",", ":")).encode() + b"\n")
                response = connection.makefile("rb").readline(256)
                if json.loads(response).get("ok") is True:
                    return
        except (OSError, ValueError, AttributeError):
            pass
        if time.monotonic() >= deadline:
            return
        time.sleep(min(.1, max(0, deadline - time.monotonic())))


def workspace_label(cwd):
    """Return a short project label without exporting a local filesystem path."""
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        return None
    path = Path(cwd)
    if path == Path.home():
        return None
    label = path.name
    for candidate in (path, *path.parents):
        if candidate == Path.home():
            break
        if (candidate / ".git").exists():
            label = candidate.name
            break
    if (not 1 <= len(label) <= 40 or "/" in label or "\\" in label
            or any(unicodedata.category(char).startswith("C") for char in label)):
        return None
    return label


def attention_key(data):
    """Match documented tool input without exporting it to the source.

    PermissionRequest has no documented tool_use_id. Count each invocation and
    correlate completions by tool/input scope, never by unrelated tool activity.
    """
    tool, arguments = data.get("tool_name"), data.get("tool_input")
    if not isinstance(tool, str) or arguments is None:
        return None
    if tool in ("Bash", "PowerShell", "apply_patch") and isinstance(arguments, dict):
        # Description is an approval reason for these canonical built-ins only.
        arguments = {k: v for k, v in arguments.items() if k != "description"}
    encoded = json.dumps([tool, data.get("cwd"), arguments], sort_keys=True,
                         separators=(",", ":"), allow_nan=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def main():
    data = {}
    try:
        data = json.load(sys.stdin)
        event = EVENTS.get(data.get("hook_event_name"))
        # A question is a tool call, not a permission request. The async call
        # returns before the answer, so its attention has a distinct lifecycle.
        if data.get("hook_event_name") == "PreToolUse":
            tool = data.get("tool_name")
            event = "question-opened" if tool in ("request_user_input", "request_user_input_async") else None
        if data.get("hook_event_name") == "PostToolUse" and data.get("tool_name") == "request_user_input":
            event = "question-answered"
        session = data.get("session_id")
        turn = data.get("turn_id") or ""
        if event and isinstance(session, str):
            path = Path(os.environ.get("PACEMAN_HOOK_SOCKET", str(Path.home() / "Library/Application Support/Paceman/hook.sock")))
            message = {"command": "agent-event", "session": session, "turn": turn,
                       "event": event, "hook": data["hook_event_name"]}
            if transient_desktop_fork(data):
                message["transientDesktopFork"] = True
            if isinstance(data.get("transcript_path"), str) and data["transcript_path"]:
                message["hasTranscript"] = True
            if data.get("hook_event_name") in ("PermissionRequest", "PostToolUse"):
                if scope := attention_key(data):
                    message["attentionKey"] = scope
                if data.get("hook_event_name") == "PermissionRequest":
                    message["approvalToken"] = str(uuid.uuid4())
            tool_id = data.get("tool_use_id")
            if isinstance(tool_id, str) and 0 < len(tool_id) <= 160:
                message["toolID"] = tool_id
            if label := workspace_label(data.get("cwd")):
                message["workspaceLabel"] = label
            deliver(message, path, data["hook_event_name"])
    except (OSError, ValueError, TypeError, KeyError):
        # Monitoring must never prevent an agent turn or approval from running.
        pass
    if data.get("hook_event_name") == "Stop":
        print('{"continue":true}')


if __name__ == "__main__":
    main()
