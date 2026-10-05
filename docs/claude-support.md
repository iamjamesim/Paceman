# Claude support: branch implementation and remaining work

This is development work on `codex/claude-monitoring`, not an installed or
release-ready integration. The existing installer still configures Codex only.

## Implemented activity foundation

The Mac receiver accepts provider-scoped Claude events alongside Codex events.
Session identities include the provider, so identical session IDs cannot collide.
Claude hooks use `prompt_id` to reject callbacks from an older turn; this requires
Claude Code 2.1.196 or later. Claude sessions never enter the Codex App Server
status reader.

`macos/claude_hook.py` observes the main session, forwards only lifecycle metadata,
opaque IDs and an optional short workspace label, and emits no decisions or text
to Claude. Tool names are hashed before forwarding; tool arguments, results,
prompts, replies and transcript paths are not forwarded or read from disk.

Questions, plan approval, tool approval and MCP elicitation are debounced for
five seconds. Unrelated parallel tools do not clear a pending question.
PermissionRequest lacks a tool-use ID, so approval attention is conservatively
retained until all observed calls of that tool have returned, or the tool batch
or turn ends. This may retain attention while an approved tool is executing.
Stop marks the main turn finished; StopFailure marks it failed. A fresh tool
start can resume a turn continued by another Stop hook. Subagent events are
ignored in this first implementation, including their independent approvals.

Hook-observed sessions clear on source restart. The last event time is retained
per provider for subsequent setup verification. Working sessions do not expire
merely because time has elapsed. Finished and failed display rows retire after
ten minutes, matching Codex's existing display retention.

## Known event limitations

- Claude has no general interrupt event. Stop does not fire on a user interrupt.
  Without another observable event, a session can retain its previous state
  until a new prompt or SessionEnd. PostToolUseFailure's is_interrupt flag is
  handled when supplied, but is not a universal cancellation signal.
- Another Stop hook can continue model reasoning without immediately emitting
  a tool event. Paceman may temporarily display Finished during that interval.
- Finished refers to the main turn, not all background tasks or scheduled work.
- Remote SSH/cloud execution and subagent-specific monitoring are not included.
- CLI, VS Code and desktop Code local sessions need separate real-event tests;
  the shared hook contract alone does not establish support.

## Usage direction

Claude usage is part of the intended feature. Do not route it into the existing
single Codex `allowance` slot: that would overwrite another provider's reading.
The current phone, relay, watch app and watch firmware still assume that slot
means Codex. None of those assumptions have been changed on this branch yet.

Retain readings separately by computer, provider, account scope (where known),
and usage window. Each window needs its own observation and reset time. When
identity is unavailable, keep readings scoped to their reporting computer;
never infer that two computers share an account or add their percentages.
An unavailable or stale Claude reading must not clear Codex, and vice versa.

Agreed activity model:

- One Live Activity per computer and one top-level robot for that computer.
- Aggregate all its Codex and Claude sessions using the existing priority:
  needs input, failed, working, finished, idle.
- Supporting text identifies which provider needs attention and shows mixed
  activity. Selecting a usage provider does not filter activity or alerts.

Usage presentation direction:

- Show both providers in the phone/watch app wherever space permits. Display
  the provider, window, remaining percentage and reset time distinctly.
- Pin a provider/account for a compact watch surface. Prefer a per-complication
  choice where supported. A new reading must not change the user's selection.
- Keep activity monitoring and notifications enabled for both providers,
  independent of the selected usage meter. No automatic provider rotation.
- Hide the picker when there is only one available provider. Do not silently
  substitute the other provider when the selected reading becomes unavailable.

Implementation default: Paceman works independently of CodexBar. Use the
currently signed-in account for each provider in the first version; additional
account switching is outside that initial scope. Claude's documented CLI
status-line input contains five-hour and seven-day limits, but that alone does
not establish a reader for VS Code-only users. Validate an independent reader
before claiming usage support across interfaces. CodexBar's readers are a
reference, not a required installation.

## Remaining implementation and verification

1. Validate an independent usage reader and add provider/window-scoped readings, including
   freshness, account changes and backward compatibility.
2. Add provider-aware installer, upgrade, removal and hook review. Preserve
   existing Claude settings and unrelated hooks. Claude-only users must not be
   required to configure Codex.
3. Update the existing Mac activity label and usage surfaces. Review the whole
   connected, empty, stale/disconnected and mixed-provider screens before
   calling the design finished.
4. Update watch transport and push selection together, so foreground updates and
   background pushes cannot overwrite a pinned provider.
5. Exercise real CLI, VS Code and desktop sessions, then independently verify
   APNs acceptance and a newly displayed notification on a locked physical phone.

Tests cover adapter-to-Unix-socket delivery, mixed-provider identity, main-turn
transitions, parallel attention, old-prompt rejection, no elapsed-time completion,
privacy and non-blocking hook failures. These are synthetic tests, not evidence
of real Claude UI or hardware delivery. No installed hooks or apps were changed.

## References

- [Claude hook contract](https://code.claude.com/docs/en/hooks)
- [Claude desktop shared configuration](https://code.claude.com/docs/en/desktop#shared-configuration)
- [Claude status-line fields](https://code.claude.com/docs/en/statusline)
- [CodexBar Claude readers](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)
- [CodexBar CLI](https://github.com/steipete/CodexBar/blob/main/docs/cli.md)
