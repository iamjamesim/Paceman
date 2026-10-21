# Native request coverage

Attention classification and remote answer support are separate. A verified
human request remains Needs input when its exact response semantics cannot be
represented. The phone's existing Continue in Codex/Claude Code and Open action
provide native continuation. Unknown requests are diagnostic only.

## Supported surfaces

| Provider | macOS | Omarchy/Linux | Shared behavior |
| --- | --- | --- | --- |
| Codex | Reviewed hooks; existing desktop owner (private stream 11); existing local App Server daemon | Reviewed hooks; existing local App Server daemon | Same request normalization, exact native response IDs, session/optional-turn attention and saved-outcome lifetime |
| Claude Code | Reviewed hooks; already-enabled native Remote Control, using the existing Keychain login | Same hooks and Remote Control, using the existing private Linux login | Same human-control classifier, response codec, actor scoping and saved-outcome lifetime; Linux also verifies process start/boot identity |

Linux has no Codex desktop IPC producer. Desktop-only extensions are covered
on that transport, not claimed as Linux features. Neither provider's cloud-only
conversations nor the separate Claude desktop app are covered by these local
integrations. Paceman does not start a daemon, turn, Remote Control connection
mode, login refresh, or agent conversation to obtain coverage.

## Finite inventories and checks

The checked-in JSON inventories in `tests/fixtures/` are extracted from installed
primary sources, not from encountered examples or public schemas used as a
substitute for private protocols:

- **Codex desktop 26.1013.40934 (20770):** producer `zS`/`BS`/`Mv`/`Lp`, UI
  `Pv`/`Lv`/`Sv`/`Iv`/`Gv`/`Jv`/`$v`, synthetic plan producer `xS`. Inventory:
  13 producer cases, 13 UI cases, four human dynamic tools, five MCP modes, and
  four relevant UI item types (including file-review context).
- **Codex CLI 0.163.0-alpha.10.2:** experimental `ServerRequest` schema generated
  by the installed bundled App Server; 11 server request methods. The desktop
  plan, picker and setup extensions are recorded separately.
- **Claude Code 2.1.304:** embedded `D8` originator map contains 92 control
  variants (16 agent, 75 client, one bidirectional); native `C4e` classifies
  exactly three as human asks. Hook builder `mu` and subagent context inheritance
  establish actor/session scope. The open `dialog_kind` string is not a finite
  list of answer contracts.

Normal tests fail when an inventoried case has no explicit classification.
Release acceptance checks read installed sources without executing their code:

```sh
python scripts/check-codex-desktop-inventory.py /Applications/ChatGPT.app
python scripts/check-claude-control-inventory.py ~/.local/share/claude/versions/2.1.304
```

For public CLI schema comparison, generate it with the target installed binary's
`app-server generate-json-schema --experimental --out <directory>`, then pass
`--app-server-schema <directory>` to the Codex checker. Build/source hashes and
method-set changes require a new semantic audit. Runtime version/owner/revision
guards remain separate. This is not a guarantee for future provider methods.

## Human requests and response boundaries

| Case | Attention | Remote response |
| --- | --- | --- |
| Codex command/file approval | Pending native ID | Exact offered decisions; file approval requires its patch; known terminal-input formats retain exact input |
| Codex user input; async question messages | Pending native ID or active unanswered message/question identity | Supported nonsecret question formats, exact question IDs and native reply envelopes |
| Codex permissions and option-picker requests | Pending native ID | Native-only; no generic approval or guessed form |
| Codex environment/onboarding/picker/setup dynamic calls | Validated known human subset, `codex_app` or absent namespace; setup `complete` excluded | Native-only |
| Codex plan request / incomplete plan item; incomplete user-input response item | Independent of terminal turn outcome; owner/item resolution ends attention | Native-only when no verified live question codec exists |
| Codex MCP modes `form`, `url`, `openai/form`, `openaiForm`, `openai/userVerification` | Pending native ID; absent/empty turn remains session scoped | Only verified typed MCP-tool approval profile; other forms, suggestions, verification, connector/browser authentication and OTP stay native |
| Codex browser policy and execution-bound database confirmations | Attention independent of codec | Supported browser site scopes retain managed-policy checks; raw-CDP and bound database execution remain native, including malformed bound summaries with approval disabled |
| Claude `can_use_tool` | Session-owned pending request ID, including agent-scoped asks | Exact supported permission suggestions; AskUserQuestion choices/text; agent-scoped, ExitPlanMode, interactive disclosures and unknown scopes stay native |
| Claude `request_user_dialog` / `elicitation` | Session-owned pending request ID; MCP form and URL variants covered | Native-only; no invented dialog handler or generic approval |
| Claude hook PermissionRequest / Elicitation / interactive PreToolUse | Debounced observed human wait | Observation only; matching tool/input hooks settle the appropriate wait |
| Claude child human hooks | Session/actor/tool-scoped waits survive parent Stop/new prompt | Native response contracts remain authoritative; child results/SubagentStop clear only that actor's hook waits |

Unsupported secret entry, missing review data, unknown policy-writing decisions
and oversized content remain native; Paceman neither truncates nor narrows the
native choice set. Submitted broker `awaitingRequestIDs` cover Paceman cards,
not all native pending decisions.

## Internal, unknown and lifetime boundaries

The inspected Codex desktop inserts human requests into its pending array only
after dispatch; it handles time reads, auth refresh/attestation, context-picker
dismissal and ordinary dynamic execution elsewhere. Invalid dynamic arguments
are returned automatically. Those negative cases remain explicitly tested even
if presented in an unexpected retained-array fixture. Claude's other control
variants are internal/client commands; hook callbacks, auth, UI/remote plumbing,
Notification and PermissionDenied do not create attention.

Stop saves an outcome independently of confirmed pending decisions. Removal of
the last matching decision restores that outcome with normal display retention.
Session close, provider disable, shutdown and verified process replacement
invalidate response access. Disconnect/missing checkpoints mean unknown, not an
empty pending set. Linux restart restores bounded attention metadata only while
the same kernel-verified process owner is alive; request content remains RAM-only.

Claude permission/dialog checkpoint arrays omit elicitation and may omit
inherited prompts. Explicit `requires_action` owner state also surfaces attention
without inventing a request ID or response card; read-only checkpoint reconciliation
clears that signal when the owner reports `running` or `idle`.
A same-worker enumerated request can resolve by confirmed
omission; unknown worker continuity cannot. Elicitation resolves by native
cancellation/result or an unambiguous ElicitationResult correlation. A server-name
fallback cannot clear concurrent sibling forms, and stale snapshots cannot
reopen a hook-resolved ID. Some inherited uncertainty can therefore require
native continuation until the provider supplies resolution evidence.

After a Linux source restart, restored Claude native attention has no saved
request IDs or worker continuity. Its aggregate uncertainty remains until the
verified owner/session ends; a partial empty checkpoint cannot prove it resolved.
Mac starts clean because its hooks cannot establish process ownership across
source restart. These recovery boundaries differ from connected-session parity.

Validation uses socket-free reducers, controlled native framing and equivalent
Mac/Linux source fixtures. Live Remote Control delivery, live child hooks,
desktop UI behavior and physical phone/watch acceptance are distinct integration
checks; local fixtures and source inspection do not claim those were exercised.
