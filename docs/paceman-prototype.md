# First Paceman prototype

Paceman is a working codename inspired by portable personal gear. The product is
an open connection between agent workspaces and the devices people choose, with
consistent state and character across surfaces. It is not primarily an approval queue.

## Finish line

One real Omarchy workspace, an iPhone with widgets, and a phone-paired ESP32 watch.
Pairing should be effortless, status legible, and workspace appearance recognizable.
Lightweight acknowledgements remain subordinate to the glanceable experience.

Acceptance checks:
- Pair the real workspace without manually copying credentials.
- Show genuine working, needs-input and finished transitions on phone and watch.
- Preserve the distinction between a Bluetooth write and observed screen rendering.
- Show the same workspace palette on phone/widget/watch with neutral fallbacks.
- Recover after source or Bluetooth disconnection; expose stale data honestly.
- Exercise extended phone locking without a debugger; record delivery gaps.
- Keep watch ownership and settings across ordinary firmware upgrades.

## Organization

### Product surfaces

The desktop is the workspace companion: collect activity and appearance, connect
a phone, show delivery status and recover the source service. Its bar panel uses
Omarchy's native styling and stays small. It does not own the watch's Bluetooth
connection.

The phone is the primary Paceman app and device manager: activity feed, widgets,
connected computer, watch pairing/reconnection, pause/resume and watch settings.
Brightness and alert sound belong on its Watch screen. Workspace appearance
originates at the desktop and should pass through the phone to the watch without
adding a separate theme picker. The watch remains the glanceable display with
lightweight local acknowledgement.

This split is partly implemented. The phone has pairing, reconnection, last
send and pause/resume. Sound is available on the Watch screen and applies to
future supported activity updates; brightness, watch theme forwarding and weather
forwarding are unfinished. The next device UI
work must restore those capabilities deliberately, rather than treating removal
of the old desktop controls as a completed migration. Phone-reported connection
and delivery receipts should also make the full route visible from the desktop.

### Code boundaries

One repo; separate source adapters and device presentations. The watch device package
retains its internal upstream layout for build correctness. Do not add speculative
frameworks, submodules or extra services. Extract Omarchy collectors when implementing
the adapter rather than copying the entire desktop product.

## Deferred

Mac workspace adapter, multi-workspace UX, additional ESP32 displays, advanced
interactions, ownership transfer UI, branding clearance and public distribution.
The earlier Android receiver is outside the maintained first-prototype scope.
