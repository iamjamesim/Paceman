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

Use `docs/home-screen-design.md` for the current phone hierarchy and review notes.
Desktop-specific decisions are in `docs/desktop-panel-design.md`. Cross-surface
consistency means consistent semantics; layout differences need a user-facing reason.

# Lifecycle engineering

Use platform-owned pending operations and delegate callbacks for work that must
survive suspension. Do not use app timers to maintain background connectivity,
replace restored operations merely because they are pending, or treat elapsed
time out of range as a stuck connection. Keep watchdogs scoped to active work
and invalidate them across lifecycle transitions. Test reconnection separately
from delivery on an already-connected device; document hardware-only gaps.
