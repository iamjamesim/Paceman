# Desktop panel design

## Job

Give someone a quick answer to “what is this computer contributing to Paceman,
and are its updates getting through?” The phone's activity feed and the desktop
summary use the same source facts, but serve different purposes. The phone is
where someone follows their work away from the computer. The desktop panel is
where they understand and control this computer's participation.

The desktop is a source, the phone manages accessories, and the watch is a
display. A working local agent and successful delivery are separate states.

## Identity and visual language

Use the companion face already drawn in the iPhone app. Adapt its outline for a
small monochrome bar icon; retain the antenna and two eyes rather than using an
unrelated rocket or introducing another symbol. The icon keeps normal weight
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
   time. There is no invented device name. A recent authenticated fetch supports
   “Receiving updates”; it does not support a watch-delivered claim.
3. **What this computer contributes.** One compact adapter/activity summary:
   Codex working, needs input, finished or no active work. It remains useful
   while the phone is away. A full session feed duplicates the phone and does
   not belong in the default desktop view. Adapter/workspace selection belongs
   here when those controls exist; do not imply scope controls are implemented.
4. **Details, inline.** Clicking the phone row expands last contact, saved-pairing
   reassurance and contextual reconnect guidance below that row. Keep the header
   and activity visible. No desktop diagnostics, credential counts, duplicate
   pairing action or routine restart action belong here. Restart appears only
   when the source is unavailable. The header QR is the single pairing action.

Example information layout (sample data, not a live status report):

```text
[companion face] Paceman                     [QR] [on]
                 SHARING ACTIVITY
-----------------------------------------------------
PHONE
[phone]          Your phone                  Just now
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
- Multiple ongoing sessions show “Codex · N active.” Count only working and
  needs-input states. If all share one state, the status reads “2 working” or
  “2 need input,” with no extra line.
- Mixed active states show the priority state on the main row and a smaller breakdown
  below, such as “1 needs input · 1 working.” Priority is needs input, working,
  then finished, matching the watch aggregate. Retained completions do not appear
  in the active count or breakdown. With only completions, use the simple
  “Codex / Finished” row; those records do not establish how many sessions are open.
  This is an activity count, not an open-window count. Reliable liveness tracking
  is a follow-up; open sessions should retain their latest status after a turn ends.
- Off/stale sources hide historical counts. Older status files without counts
  fall back to the aggregate; do not guess the distribution.

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

Normal removal belongs on the phone. A future desktop “Revoke phone access”
control would support a lost phone, but requires reliable device identification
and deliberate confirmation. Anonymous credential counts cannot identify physical
phones. The sharing switch currently stops access while preserving pairing.

## Evidence limits

Contact expires after 30 seconds; the source heartbeat expires after 20 seconds.
Phone contact is currently a successful authenticated snapshot response or stream
write, including diagnostic clients. Do not infer an always-connected phone,
working APNs or Bluetooth status. No watch/weather placeholder row appears until
there is useful device-reported information to display.

Validate normal, first-run, waiting and stopped states in a separate preview with
sample data. Never inject fixture status into the live service to make a good
looking screenshot.

Run `bash scripts/preview-desktop.sh` to review four labeled sample states using
the same panel component and current Omarchy theme. The installed service and
its status are unaffected by the preview. Set `PACEMAN_PREVIEW_SESSIONS=1` to
compare one session, two working sessions, and mixed-state summaries.
