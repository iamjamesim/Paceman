# Phone home design

The home screen answers, in order:
1. Which computer is this?
2. Is its activity current, or is the app recovering the connection?
3. What are the agents doing; does anything need input?
4. Is the watch connected, and when was activity last sent to it?

Keep computer identity and connection freshness above the activity divider.
Activity belongs below it; the watch is a separate destination. Preserve the
outline Paceman brand mark. The smaller filled robots describe agent state only,
with the state label stacked below. A single session needs no count headline.
Historical robots are still and muted. No received activity is not historical activity.
Background transport registration and alert permission are not home-screen setup steps.

## Review checkpoint: 2026-09-18

The user-provided connected/needs-input, connected/empty, and disconnected/empty
screens establish the current layout baseline. Keep that organization.

Final refinements completed:
- Removed the repeated disconnected-empty explanation.
- Matched watch and computer heading type scales.
- Both receipt times say “just now” for the first ten seconds.
- The phone combines sessions lacking both a useful name and project by provider.
  Named/project-identified sessions remain individual. Groups retain all state counts,
  including idle, and choose needs-input → working → finished → idle for their robot.
  Rows sort by that priority, then stable identity. One display row has no duplicate
  aggregate headline. Multiple display rows retain a compact overview.
- Desktop retains its compact adapter summary; watch retains one aggregate state.
  Phone detail is justified by session identity, not extra available space.

Validation: 28 iOS tests passed, including mixed named/unnamed grouping, count
preservation, stable ordering, and silent registration without alert permission.
Grouped rows were visually checked at normal and maximum accessibility text size;
connected, empty, and unavailable layouts were checked during this refinement pass.

Do not confuse visual acceptance with transport reliability. Background APNs
delivery and sender throttling remain separate engineering concerns documented
in `direct-push-test.md`.

## Watch detail refinement

Home and detail reuse WatchConnectionSummary and ReceiptTimeLabel for connection
copy, status color, delivery time, and the ten-second “just now” window. Detail
uses a centered, larger watch illustration and name, with the shared status below.
The home card retains its compact header. Detail is followed by Watch updates and Alert
sound switches. The relay explanation, metadata table, and large Pause action
are removed. Updates-off retains pairing and the sound preference. Bluetooth
availability guidance is contextual; ordinary recovery remains automatic.

Preferences are stored per authenticated watch ID. Existing global values migrate
only to the paired receipt's identity; new identities default to updates and sound
on. Removing the matching accessory clears its preference record. This prepares
preference ownership for multiple devices; it does not implement simultaneous
multi-watch transport or workstation subscription/permission management.

Validation: 29 tests passed including legacy preference migration, persistence,
identity isolation, and removal. Connected, updates-off, disconnected and maximum
accessibility-size detail previews were inspected. Phone build succeeded. Physical
switch/resume and sound behavior still require hands-on acceptance.

Watch status copy is shared by feed and detail: Connected, Connecting…,
Reconnecting…, Updates off, Not connected, Bluetooth off, Bluetooth permission
needed, and Bluetooth unavailable. Reconnecting requires an active/scheduled
recovery attempt. User intent (updatesEnabled) is separate from transport running
(enabled): a terminal failure stops transport without saving an Off preference.
Detail shows short actionable guidance and Try again only for a stopped connection;
transport diagnostics are not used as management-page copy. The expanded suite
passes 30 tests, including state precedence and failure/off/recovery distinctions.
