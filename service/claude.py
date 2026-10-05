"""Hook-observed Claude main-session state; no transcript reads or idle watchdog."""
from dataclasses import dataclass, field
import time


@dataclass
class ClaudeSession:
    turn: str = ""
    base_state: str = "idle"
    workspace_label: str | None = None
    updated: float = field(default_factory=time.time)
    # Pending attention survives unrelated parallel tool completions.
    waits: dict[str, float] = field(default_factory=dict)
    tools: dict[str, str] = field(default_factory=dict)

    def state(self, now):
        if self.base_state in ("finished", "failed", "idle"):
            return self.base_state
        return "needs_input" if any(due <= now for due in self.waits.values()) else "working"

    def receive(self, command, now, delay):
        event, hook, turn = (command.get(k) for k in ("event", "hook", "turn"))
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
