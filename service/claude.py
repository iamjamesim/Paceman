"""Hook-observed Claude main-session state; no transcript reads or idle watchdog."""
from dataclasses import dataclass, field
import hashlib
import time


@dataclass
class ClaudeSession:
    turn: str = ""
    base_state: str = "idle"
    workspace_label: str | None = None
    remote_session_id: str | None = None
    updated: float = field(default_factory=time.time)
    # Pending attention survives unrelated parallel tool completions.
    waits: dict[str, float] = field(default_factory=dict)
    tools: dict[str, str] = field(default_factory=dict)
    child_waits: dict[str, float] = field(default_factory=dict)
    child_tools: dict[str, str] = field(default_factory=dict)

    def state(self, now):
        if any(due <= now for due in self.child_waits.values()):
            return 'needs_input'
        if self.base_state in ("finished", "failed", "idle"):
            return self.base_state
        return "needs_input" if any(due <= now for due in self.waits.values()) else "working"

    def receive(self, command, now, delay):
        event, hook, turn = (command.get(k) for k in ("event", "hook", "turn"))
        actor = command.get('actor')
        if actor:
            # Child hooks carry the host journal's current prompt ID, not a
            # stable child turn. Their human waits belong to this session/actor.
            self.turn = self.turn or turn
            prefix = actor + ':'
            tool, tool_id = command.get('tool'), command.get('toolUse')
            if hook == 'SubagentStop':
                self.child_waits = {k: v for k, v in self.child_waits.items() if not k.startswith(prefix)}
                self.child_tools = {k: v for k, v in self.child_tools.items() if not k.startswith(prefix)}
            else:
                if 'remoteSessionID' in command:
                    self.remote_session_id = command['remoteSessionID']
                if hook == 'PreToolUse' and tool_id:
                    self.child_tools[prefix + tool_id] = tool
                if event == 'question-opened':
                    self.child_waits.setdefault(prefix + 'question:' + (tool_id or tool), now + delay)
                elif event == 'needs-input':
                    self.child_waits.setdefault(prefix + 'permission:' + tool, now + delay)
                elif event == 'tool-ended':
                    self.child_tools.pop(prefix + (tool_id or ''), None)
                    self.child_waits.pop(prefix + 'question:' + (tool_id or tool), None)
                    if not any(k.startswith(prefix) and value == tool for k, value in self.child_tools.items()):
                        self.child_waits.pop(prefix + 'permission:' + tool, None)
            self.updated = time.time()
            return True
        if self.turn and turn != self.turn and hook != "UserPromptSubmit":
            return False
        if hook == "SessionStart":
            return False
        if hook == "UserPromptSubmit":
            if self.turn == turn:
                return False
            self.turn = turn
            self.waits.clear()
            self.tools.clear()
            self.base_state = "working"
        elif self.base_state in ("finished", "failed", "idle") and self.turn:
            # Stop hooks can continue a turn. A fresh PreToolUse proves work
            # resumed; a delayed result/permission event alone does not.
            if hook != "PreToolUse":
                return False
            self.base_state = "working"
        else:
            self.turn = turn
            self.base_state = "working"
        if "remoteSessionID" in command:
            self.remote_session_id = command["remoteSessionID"]
        self.workspace_label = command.get("workspaceLabel") or self.workspace_label
        self.updated = time.time()
        tool, tool_id = command.get("tool"), command.get("toolUse")
        if hook == "PreToolUse" and tool_id and tool:
            self.tools[tool_id] = tool
        if event == "question-opened":
            self.waits.setdefault("question:" + (tool_id or tool), now + delay)
        elif event == "needs-input":
            scope = "input:" + command["inputID"] if hook == "Elicitation" else "permission:" + tool
            self.waits.setdefault(scope, now + delay)
        elif event == "input-resolved":
            self.waits.pop("input:" + command["inputID"], None)
        elif event == "tool-ended":
            self.tools.pop(tool_id, None)
            self.waits.pop("question:" + (tool_id or tool), None)
            # PermissionRequest has no tool_use_id. Wait until all observed
            # calls of that tool have returned rather than clear another call.
            if tool not in self.tools.values():
                self.waits.pop("permission:" + tool, None)
        elif event == "batch-ended":
            self.waits.clear()
            self.tools.clear()
        elif event in ("completed", "failed", "interrupted"):
            self.base_state = {"completed": "finished", "failed": "failed", "interrupted": "idle"}[event]
            self.waits.clear()
            self.tools.clear()
        return True

    def resolve_tools(self, tools, pending_tools):
        had_child_waits = bool(self.child_waits)
        pending = set()
        for value in pending_tools:
            actor, tool = value if isinstance(value, tuple) else (None, value)
            if isinstance(tool, str):
                pending.add((actor, hashlib.sha256(tool.encode()).hexdigest()))
        for entry in tools:
            tool_id, tool, *actors = entry
            actor = actors[0] if actors else None
            tool_hash = hashlib.sha256(tool.encode()).hexdigest()
            calls, waits = (self.child_tools, self.child_waits) if actor else (self.tools, self.waits)
            prefix = actor + ':' if actor else ''
            if calls.get(prefix + tool_id) != tool_hash:
                continue
            waits.pop(prefix + 'question:' + tool_id, None)
            if (actor, tool_hash) not in pending:
                waits.pop(prefix + 'permission:' + tool_hash, None)
        if had_child_waits and self.base_state in ('finished', 'failed') and not self.child_waits:
            self.updated = time.time()
