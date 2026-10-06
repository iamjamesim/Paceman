# Product design changes

Prefer omission. Add an element only when its absence creates a specific
misunderstanding or prevents a necessary user action. Preserve established
branding and successful layouts unless there is a concrete reason to change them.

Before editing a product screen:
- Identify the user's questions in priority order and the minimum information
  needed to answer them. Inspect the real behavior behind status and action labels.
- Do a subtraction pass: remove repeated facts, irrelevant implementation details,
  and actions for work the app already performs automatically.
- State the specific defect and the smallest coherent change. A request for an
  assessment is not permission to keep redesigning a satisfactory screen.

Before installing or presenting a design as finished:
- Review the whole affected screen, not just the edited component. Compare the
  relevant connected, empty, stale/disconnected, and multiple-item states together.
  Check long text and accessibility sizing when layout changes affect them.
- Each element must answer a distinct user question or enable a necessary action.
  Internal errors belong on the main screen only when the user needs to act there.
- Use stable labels for automatic recovery; do not expose request-by-request churn.
  Distinguish fresh activity, historical activity, and no received activity.
- Report which states were actually checked. Separate functional defects from
  optional polish. Do not install each exploratory idea as a finished design.
- Stop when the user questions are answered clearly. Do not manufacture more
  refinements just to produce work.

Use `docs/architecture.md` and `docs/data-lifecycle.md` for current system
semantics. Cross-surface consistency means consistent meanings; layout differences
need a user-facing reason.

# Documentation

Keep permanent documentation concise and limited to critical current behavior.
Put migration steps and verification results in release notes or PRs, and avoid
repeating details across architecture, lifecycle and protocol docs.

# Lifecycle engineering

Use platform-owned pending operations and delegate callbacks for work that must
survive suspension. Do not use app timers to maintain background connectivity,
replace restored operations merely because they are pending, or treat elapsed
time out of range as a stuck connection. Keep watchdogs scoped to active work
and invalidate them across lifecycle transitions. Test reconnection separately
from delivery on an already-connected device; document hardware-only gaps.

# Agent-led Mac installation

When guiding a Mac installation or pairing, follow `macos/README.md` through hook
review and a real Codex event check. Running `macos/install.py` and pairing the
phone do not complete session monitoring. Show the user the exact Paceman hook
command and what data it sends. For an app user, direct them specifically to
Codex **Settings → Hooks → User config (All projects)**; for a CLI user, use
`/hooks` or **Review hooks** at startup. Name the eight Paceman event rows and
their plain-language purposes from `macos/README.md`, explain that Codex calls
each row **Hook 1**, and show how to expand one to verify the Paceman command.
Stay with the user while they review the entries. Do not trust hooks on the
user's behalf or bypass Codex's review. After their review, use a fresh saved
local task in the Codex interface they use (app or interactive CLI); do not use
`codex exec --ephemeral` for installation verification. Verify
`lastAgentEventAt` advances in `pacemanctl status`, the task replies successfully,
and Paceman shows that task as Finished. A start event alone is insufficient.
Installation and diagnostic checks must not leave orphaned or invalid activity.
Resolve any confirmed orphaned or invalid state created by the check before
handing off, preserving real user sessions. Report the installation as partial
if review or verification is pending or fails, or cleanup remains unresolved.

For iPhone notifications, pairing and hook delivery are insufficient. The
normal Mac installer prepares the relay sender before pairing. Follow the Mac
notification check in `macos/README.md`: preserve any existing private
config/key without exposing it, verify the per-user push worker against the
source database, confirm APNs acceptance, and ask the user to confirm a new
notification on the physical phone. Treat Apple acceptance and phone display
as separate checks.

Explain the installed Mac components in plain language: one Paceman background
item runs the local source and optional notification sender, the menu-bar app
controls Sharing and phone access, opens at login by default, and reviewed Codex
hooks supply activity. The menu app's Open at Login setting is separate from
Sharing, so it remains accessible while sharing is paused.
After installation, verify the item appears as Paceman in System Settings →
General → Login Items & Extensions. Show how Sharing pauses both workloads and
how Manage Paceman uninstalls the app, hooks, local pairing data, and APNs key.
Do not claim an Apple Development signature is a public distribution signature;
Developer ID signing and notarization are separate release work.
