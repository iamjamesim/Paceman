# Desktop panel design

The [visual reference](desktop-visual-reference.md) shows the canonical rendered
states and explains what the macOS implementation should preserve.

## Job

Give someone a quick answer to “what is this computer contributing to Paceman,
and are its updates getting through?” The phone's activity feed and the desktop
summary use the same source facts, but serve different purposes. The phone is
where someone follows their work away from the computer. The desktop panel is
where they understand and control this computer's participation.

The desktop is a source, the phone manages accessories, and the watch is a
display. A working local agent and successful delivery are separate states.

## Identity and visual language

Use the companion face already drawn in the iPhone app. The iPhone and Mac now
compile the same vector in `ios/Shared/PacemanMark.swift`; Omarchy's
`desktop/plugin/PacemanMark.qml` uses that vector's cropped app-icon coordinates.
Keep both eyes identical and mirrored around the face center at every size.
The icon keeps normal weight
while the desktop runs and dims when it stops. A sleeping phone is not an urgent
error, and the icon does not animate on every agent event.

Use the same hero structure as Omarchy's Bluetooth, audio and network panels:
display-sized mark, Paceman title, small uppercase status, trailing QR button
and sharing switch. Use the native `PanelHero` component and shell fonts,
spacing, borders, foreground and muted colors throughout.
No independent color palette, extra cards, oversized headings or permanent
troubleshooting buttons. Normal content width is 380 logical style units.

## Information hierarchy

1. **Paceman.** A stable native header identifies the app and whether this
   computer is sharing. The sharing switch is a persistent
   choice, honored across login and upgrades. Off disables login startup and
   stops the service; On restores both. A service condition also prevents an
   accidental manual start from overriding the saved Off choice.
2. **Phone contact.** A phone icon, understandable connection text and last-contact
   time. Names and platforms come from the paired app. A recent authenticated fetch supports
   “Receiving updates”; it does not support a watch-delivered claim.
3. **What this computer contributes.** One compact adapter/activity summary:
   Codex working, needs input, finished or no active work. It remains useful
   while the phone is away. A full session feed duplicates the phone and does
   not belong in the default desktop view. Adapter/workspace selection belongs
   here when those controls exist; do not imply scope controls are implemented.
4. **Details, inline.** Clicking a connection row expands its own last contact, pairing date,
   contextual reconnect guidance and a secondary “Remove access…” action. Keep the header
   and activity visible. No desktop diagnostics, credential counts, duplicate
   pairing action or routine restart action belong here. Restart appears only
   when the source is unavailable. The header QR is the single pairing action.

Example information layout (sample data, not a live status report):

```text
[companion face] Paceman                     [QR] [on]
                 SHARING ACTIVITY
-----------------------------------------------------
PHONE
[phone]          Alex’s iPhone                  Just now
                 Receiving updates                   >
-----------------------------------------------------
ACTIVITY
Codex                                 Working [agent]
```

The phone row changes independently of the local Codex summary. If sharing is
enabled but the phone is away, show waiting/last contact plus a recovery hint;
never convert that into a fresh-pairing prompt.

Activity uses per-state session counts from the same snapshot as its aggregate:

- One session keeps the simple Codex/status row.
- Multiple process-verified sessions show “Codex · N sessions.” An open session
  remains counted after its turn finishes or is interrupted. If all share one
  state, the status reads “2 working,” “2 need input,” “2 finished,” or “2 idle.”
- Mixed states show the priority state on the main row and a smaller breakdown
  below, such as “1 needs input · 1 working.” Priority is needs input, working,
  finished, then idle, matching the watch aggregate.
- Counts represent observed sessions with living Codex owners, not terminal
  windows. A detached tmux session remains live. Process exit removes its session;
  old unowned completions cannot inflate the list. One open session retains its
  latest state in the simple row, including Finished.
- Off/stale sources hide historical counts. Older status files without counts
  fall back to the aggregate; do not guess the distribution. Older sources without
  the process-verification marker use the conservative working/needs-input count.

This is a summary, not a session list. A future inline session list would need
useful task/project names before it can explain which task needs attention.

## States and actions

| State | Main content | Primary action |
| --- | --- | --- |
| No phone paired | Connect your phone; brief setup instruction | Show pairing code |
| Recent phone contact | Phone receiving updates; last contact | None needed |
| Paired, no recent contact | Waiting for phone; last contact and how to resume | Open the app on the phone; do not ask to pair again |
| Sharing switched off | Sharing off; activity paused | Turn sharing on |
| Desktop stopped or heartbeat expired | Sharing unavailable; explain consequence | Restart Paceman |
| Pairing overlay | QR, where to scan, expiry; Escape or outside click to close | Generate a new code only when needed |

Pairing uses a centered QR over a workspace-sized scrim, matching Omarchy’s
Wi-Fi QR overlay. The bar panel does not navigate between pages. Escape
collapses expanded phone details before closing the panel; in the QR overlay,
it dismisses the overlay. Recovery errors use plain language. Keyboard and mouse
controls use the same focus treatment.

Activity combines the watch’s agent-face glyph with explicit words. Working uses
the same gentle 1.3-second fade each way; attention and completion stay static in
the desktop panel. Animation stops when the panel closes. Text always carries
the state, so neither motion nor icon recognition is required.
The mark occupies a fixed trailing slot, with the state label right-aligned
beside it. Reserve that slot in idle/off states too, so changing labels or hiding
the mark never shifts the visual anchor or the row height.

Normal removal belongs on the phone. Desktop **Remove access…** supports a lost
phone or obsolete connection. Its inline confirmation names the connection,
explains that updates stop and watch pairing remains, and defaults keyboard focus
to Cancel. Escape first cancels confirmation, then collapses details, then closes
the panel. Removal is available while sharing is off. Long connection lists scroll
within the panel, including keyboard focus following the selected control.

Every credential has its own contact time. Named app installations get a phone
icon only when their reported platform supports that description. Pairing requires
installation metadata; names are never merged or inferred to be physical phones.
The section reads **CONNECTIONS** when it contains non-phone clients. Re-pairing with
proof of the current credential replaces that installation’s access in place.

## Evidence limits

Contact expires after 30 seconds; the source heartbeat expires after 20 seconds.
Contact is a successful authenticated snapshot response for
that particular credential; diagnostic clients cannot refresh another row. Do not infer an always-connected phone,
working APNs or Bluetooth status. No watch/weather placeholder row appears until
there is useful device-reported information to display.

Validate normal, first-run, waiting and stopped states in a separate preview with
sample data. Never inject fixture status into the live service to make a good
looking screenshot.

Run `bash scripts/preview-desktop.sh` to review four labeled sample states using
the same panel component and current Omarchy theme. The installed service and
its status are unaffected by the preview. Set `PACEMAN_PREVIEW_SESSIONS=1` to
compare one session, two working sessions, and mixed-state summaries.

The macOS menu-bar client follows the same header, phone-contact, activity,
pairing, sharing and removal hierarchy. Its counts are hook-observed sessions;
the Linux process-liveness guarantee above does not apply. The native Mac panel
component was visually reviewed in a temporary window with empty, recent,
waiting, stopped, sharing-off and multiple-connection fixtures. The QR sheet was
also checked after correcting a cropped image. The actual menu-bar popover still
needs a hands-on check because the UI inspection tool cannot access menu-only apps.

On the Mac, the activity row distinguishes a missing hook configuration from
hooks installed with no event received and from ordinary idle after a past
event. Setup guidance stays within that row and appears only while sharing is
running. It does not infer hook trust from configuration files or repeat setup
instructions after a source restart that retains prior event evidence. The
missing, first-event, established idle, active-with-missing-hook, sharing-off,
and stopped layouts were compared in the full panel, including long phone names
and an accessibility text-size preview.

The Mac panel now has a quiet **Manage Paceman…** action after Activity. Its
sheet answers what the one background item does, how the Sharing switch pauses
both the source and optional notification sender, and what complete uninstall
removes. The destructive action has a second confirmation and explains that the
phone retains its computer card until removed there. No service process names or
per-request diagnostics appear in the main panel. The full first-run, paired,
multiple/stale connection, and sharing-off layouts were checked with this action;
the sheet and confirmation were checked at normal and accessibility text sizes.
