# Phone home design

The home screen answers, in order:
1. Are Live Activities and Omarchy Watch available to show updates?
2. Which computers are connected, and is their activity current?
3. What are the agents doing; does anything need input?

Keep computer identity and connection freshness above the activity divider.
Activity belongs below it; the custom watch is a separate destination beside
Live Activities above the computer cards. Preserve the
outline Paceman brand mark. The smaller filled robots describe agent state only,
with the state label stacked below. A single session needs no count headline.
For a grouped provider row, keep its session count in the name and show the
state distribution below only when those sessions have different states.
Historical robots are still and muted. No received activity is not historical activity.
Background transport registration and alert permission are not home-screen setup steps.
The Live Activities status describes iPhone availability, not whether an active
session currently has an activity or whether every computer has completed a
background registration attempt. Its detail page uses the same centered
illustration and status as the other device pages, then shows only the computers
currently displayed by ActivityKit. A computer still being checked for automatic
start appears as guidance only while that condition exists. Connect belongs in
the Computers heading.
Opening a Live Activity lands on its computer card, where the current agent
rows are already visible, rather than the computer's connection-management
detail. A finished Live Activity ends automatically after a brief resting period;
opening its computer card does not acknowledge work. The card is a current/last-known view, not a durable
activity-history screen.

## Multiple-computer behavior: 2026-09-23

Computers are peers. Each has the same full-width tappable card header, spacing,
connection state, activity rows, history treatment, and rename/removal detail.
Pairing order stays stable; repairing one keeps its position, and removing one
leaves the others' credentials, caches and state intact. Activity does not reorder
cards while the user is reading or tapping. If two display names match, show
their source hosts under those names to distinguish them.

Each computer fetches and caches independently. The watch combines only fresh
activity by urgency across all sources. Appearance and allowance each use the
first paired source with a valid value as a stable default, whether or not that
computer is currently active; removing it selects the next valid value. Live
Activities are independently owned by their source computers.
The old primary/additional storage keys migrate into one ordered list. The first
entry is only the default position for legacy single-computer navigation.

## Two-computer alpha pass: 2026-09-22

Keep the current card hierarchy while adding another independently paired
computer below the first. Each card names its own computer, reports its own
freshness and activity, and links to its own rename/removal detail. The watch
card remains one destination below the computers. The watch receives the
highest-priority fresh state across sources: needs input, working, finished,
then idle. Source credentials, cached snapshots, push registrations, and
removal stay separate. No tab bar is introduced until actual multi-machine use
shows a navigation problem.

The connected/multiple-session, second-computer empty, and second-computer
stale states were rendered in the iPhone simulator. The connected two-computer
screen was also inspected at accessibility extra-extra-large text size; it
remains vertically scrollable. A long computer name and task title were
inspected at normal text size and wrap within their card. Physical-device
acceptance is pending. The Mac panel component and pairing sheet were inspected
with fixture states; the actual menu-bar popover and real Codex/ChatGPT Work hook
delivery remain separate checks.

Connection and content answer different questions. `Connecting…`, `Checking…`,
and `Reconnecting…` describe the computer link. A receipt time says when this
phone last heard from it. Fresh activity is presented normally; expired activity
may remain below the divider only as muted `Last known activity`. A stale source
state never drives the decorative watch preview. The watch card independently
describes the phone-to-watch link and retains its last successful delivery time
across app launches.

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

## Computer detail refinement

Match watch detail's centered illustration, name, connection status, and receipt
time. Home and detail share ComputerConnectionState and ComputerReceiptLabel.
A stale snapshot while the app checks for current data says Checking; a failed
request says Reconnecting; revoked access takes precedence. Display name and Remove computer
are the only routine actions. Recovery guidance appears while reconnecting; QR
pairing appears only after access removal. Endpoint and identity diagnostics stay
in developer tools. Removal failure preserves pairing and reports failure.

Names belong to authenticated source IDs. The old global name migrates once to
the paired source; successful removal clears only that source's name.
Validation: 32 tests passed, including connection precedence and name migration /
identity isolation. Connected, reconnecting, revoked, waiting, stale, and long-name
maximum-accessibility previews were inspected. Both simulator and signed device
builds succeeded. Accessibility names use proportional type to avoid broken words.

Computer detail's removal action is separated from the editable-name row, centered
and explicitly destructive, with a subtle neutral button background. Confirmation
and server-confirmed removal behavior remain intact. The decorative laptop now
shows two tiled terminal panes, without window-control dots, old branding, or a
sample agent state.
This visual-only follow-up built successfully for simulator and device. Connected,
reconnecting, revoked, maximum accessibility text, and the shared pairing
illustration in the light theme were visually checked. Existing behavior tests
were not rerun for these drawing and button-style changes.

Watch detail now includes Remove watch below preferences, sharing DeviceRemovalButton
with computer detail. Both require confirmation; removal errors preserve pairing.
See pairing-and-removal.md for the watch ownership distinction and validation limits.

## Daily-use state contract

Appearance is selected once in Settings and applies across every computer card.
The app follows iPhone light/dark appearance for families with both variants;
Sakura Mochi and Miasma remain dark. The watch illustration and Live Activity
preview use the selected dark glance palette even when the phone is light.
At home-tile size, Live Activities show a small status robot and text lines on
the dark card; the tile's status reports availability, not an agent state. The
custom watch shows a three-letter day, status-robot sample, and a dominant time
without shrinking the full detail face.

The normal screen does not turn temporary absence into setup work:

| Situation | Computer card | Activity area | Watch card |
| --- | --- | --- | --- |
| First connection, no snapshot | `Connecting…` | No activity received yet | Independent watch state |
| Current snapshot | Receipt time only | Current activity | Independent watch state |
| Cached snapshot while checking | `Checking…` plus last receipt | Muted last-known activity | Independent watch state |
| Request failed | `Reconnecting…` plus last receipt | Muted last-known activity | Independent watch state |
| Access revoked | `Access removed` and Reconnect | No cached activity | Independent watch state |

Automatic recovery has no Retry action on the home screen. Computer detail says
only that reconnection happens when the computer is awake and online. Pairing UI
returns only for explicit removal or confirmed revocation.

Validation on 2026-09-21 covered current single-session, stale/checking computer
detail, reconnecting with historical activity, disconnected watch, and first-contact
layout at an accessibility text size. The iOS suite passed 53 tests and both
simulator and signed-device builds succeeded.
