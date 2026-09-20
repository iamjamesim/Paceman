# Development handoff

Start with README.md, docs/architecture.md and docs/validation.md. Keep this file
focused on current next steps; do not append chronological development diaries.

## Current delivery work

P0 monitoring includes iPhone Live Activities/attention notifications, Apple Watch,
and the custom watch. The selected phone-to-watch path is event-driven:
source → APNs → phone callback → paired-source fetch → existing BLE write.
The accessory polling experiment has been removed from the app and firmware.

For phones registered in notification mode, the desktop worker sends needs-input
and finished as attention notifications, and working/idle as passive notifications
(no screen wake or sound; still present in the notification list). This is normal
worker behavior with no test flag. Background-only registrations retain their
existing low-frequency, best-effort behavior; enabling notifications still requires
explicit permission. Live Activity delivery remains independent.

One visible finished notification has been observed to update the watch while
the phone was locked. Repeated delivery, passive transitions and longer idle periods
still need physical validation. Follow [phone-monitoring-handoff.md](docs/phone-monitoring-handoff.md)
for the single desktop deployment and [direct-push-test.md](docs/direct-push-test.md)
for validation. Keep keys, actual configs and device logs out of commits.

## Next milestone

Connect real Omarchy activity and appearance through the source service to the
existing iPhone app and phone-owned watch. Reuse relevant upstream collectors;
do not start the old desktop Bluetooth owner or install duplicate agent hooks.

The Omarchy machine uses the installed desktop package as the persistent user service
`paceman-source.service`; the old Omarchy Watch desktop daemon and bar widget
have been uninstalled. The separate Omarchy Watch for Codex event-hook plugin
remains installed because Paceman receives its events. The existing
private HTTPS route is reused. The prior Linux source database was migrated with
SQLite backup, preserving its source identity and paired client credential.
The source starts at login and restarts on failure. Run
`bash scripts/install-desktop.sh` to install/update the app and status panel.
Code lives in `~/.local/lib/paceman`; active data is in `~/.local/state/paceman`.
The checkout database is retained as a pre-install copy. See docs/desktop.md for
setup and docs/roadmap.md for the next product milestones. The panel has inline
phone details, a workspace QR overlay, a persistent sharing switch and a compact
multi-session activity summary. The receiver now tracks Codex process ownership
through kernel peer credentials; quiet/finished open sessions survive restart,
and exited owners leave the summary. Existing hooks are unchanged. Identified pairing, per-client contact and access
removal from either side are implemented. Legacy credentials stay unidentified
until the updated app registers them. Mac builds and all 21 iOS tests passed;
the updated app is installed on the iPhone and fetching successfully. Complete
the physical acceptance in docs/pairing-and-removal.md before a device release.
Check it with `systemctl --user status paceman-source.service`. Do not start a
second source while testing the phone.

1. Complete physical pairing/removal acceptance: legacy identification is verified;
   test same-installation reconnection, independent connections and removal failures.
2. Verify live Omarchy transitions on the updated phone over private HTTPS.
   The in-place update preserved working fetches; full live-event and visible
   watch routing still need acceptance. See docs/omarchy-routing.md.
3. Extend phone-to-watch profile forwarding for desktop appearance and freshness.
4. Verify transitions, theme continuity, disconnect/reconnect and prolonged phone
   locking on physical devices; distinguish BLE acceptance from visible rendering.
5. Polish one watch face and one phone widget before adding platforms or actions.

## Development environments

Mac: Xcode, phone app/widgets, signing and attached-watch flashing.
Omarchy: real agent events, desktop appearance, source service and integration tests.
Both use this repository; credentials and device-specific runtime state stay local.

## Compatibility

- Preserve existing bundle IDs, App Group, Keychain identity, BLE UUIDs and packet
  versions unless a deliberate migration is part of the task.
- The development watch is now phone-paired. Ordinary firmware updates preserve
  NVS; do not erase flash or attempt desktop ownership recovery as a routine step.
- One source, multiple sessions, one optional watch is the current UI scope.
- Source presentation can customize palette and typography; no theme picker,
  wallpaper controls, extra tabs, or approval-centric dashboard are in scope.
- No real-agent integration, reliable background delivery or hardware rendering
  should be inferred from simulator fixtures or mocked push tests. The Omarchy
  adapter has automated socket/HTTP/SSE coverage; live device evidence is pending.

The earlier Android receiver experiment and development history were preserved
outside this checkout before creating the initial Paceman commit. They are not
part of the maintained first-prototype scope.
