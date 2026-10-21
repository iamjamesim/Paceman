# Native request coverage

Verified human requests remain Needs input even when Paceman cannot answer them
remotely. Use the existing Continue in Codex/Claude Code or Open action. Internal
and unknown requests are diagnostic only; they never create approval buttons.
Codex's retained pending array is a producer-filtered subset of transport requests;
internal time/auth/context calls and ordinary tool execution remain excluded.

## Supported surfaces

| Provider | macOS | Omarchy/Linux |
| --- | --- | --- |
| Codex | Reviewed hooks; existing desktop owner (private stream 11) or local App Server daemon | Reviewed hooks; existing local App Server daemon |
| Claude Code | Reviewed hooks; already-enabled Remote Control and existing Keychain login | Same hooks and Remote Control; existing private Linux login |

Shared flows use the same normalization and decision lifetime. Linux has no
Codex desktop IPC. Cloud-only conversations and the separate Claude desktop app
are outside these integrations. Paceman starts no daemon, turn or Remote Control
mode and does not refresh native credentials.

## Response boundaries

| Human request | Remote response |
| --- | --- |
| Codex command/file approvals; terminal input | Exact offered decisions/input; file approval requires its review patch |
| Codex user input and async questions | Supported nonsecret question formats and exact native IDs |
| Codex permissions, option pickers, environment/onboarding/setup inputs and plans | Native-only; setup completion and ordinary dynamic tools are internal |
| Codex MCP requests, including session-scoped forms and URL/verification modes | Only the verified MCP-tool approval profile; other forms, authentication and OTP stay native |
| Codex browser/database confirmations | Supported site scopes retain managed-policy checks; raw-CDP and execution-bound database confirmations remain native, including malformed bound summaries |
| Claude tool permission and AskUserQuestion | Exact supported suggestions/choices/text; agent-scoped asks, ExitPlanMode, interactive disclosures and unknown scopes stay native |
| Claude dialogs and MCP elicitation | Native-only; no guessed dialog handler |
| Claude main/child human hooks | Observe attention only; matching results or child completion settle the corresponding scope |

Secret entry, missing review data and oversized content remain native. Paceman
does not truncate or narrow the native choice set. Explicit Claude
`requires_action` owner state can surface attention without inventing a request ID.

## Compatibility and recovery limits

[Decision lifetime](data-lifecycle.md#questions-and-approvals) is separate from
turn outcome and submitted mobile-card lifetime. Disconnect is unknown, not empty.
Claude checkpoints enumerate permission/dialog requests, omit elicitation and
may omit inherited prompts; omission resolves only a known same-worker request
in an enumerated domain. Exact native results or unambiguous elicitation hooks
can resolve requests without clearing siblings.

Linux restores bounded attention only for the same verified live process.
Restored Claude aggregate uncertainty has no saved request IDs and remains until
the owner/session ends; a partial empty checkpoint cannot clear it. Mac starts
clean across source restart because hooks cannot verify process ownership.

Versioned source inventories live in the [Codex desktop](../tests/fixtures/codex-desktop-inventory.json),
[App Server](../tests/fixtures/codex-appserver-inventory.json) and
[Claude](../tests/fixtures/claude-control-inventory.json) fixtures.
Tests require explicit classification of each known case. Run the
[Codex](../scripts/check-codex-desktop-inventory.py) and
[Claude](../scripts/check-claude-control-inventory.py) inventory checks for provider
updates; source or method-set drift requires a fresh semantic audit.
