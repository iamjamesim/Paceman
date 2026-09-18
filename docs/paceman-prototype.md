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

One repo; separate source adapters and device presentations. The watch device package
retains its internal upstream layout for build correctness. Do not add speculative
frameworks, submodules or extra services. Extract Omarchy collectors when implementing
the adapter rather than copying the entire desktop product.

## Deferred

Mac workspace adapter, multi-workspace UX, additional ESP32 displays, advanced
interactions, ownership transfer UI, branding clearance and public distribution.
The earlier Android receiver is outside the maintained first-prototype scope.
