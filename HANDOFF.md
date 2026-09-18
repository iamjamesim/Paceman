# Development handoff

Start with README.md, docs/architecture.md and docs/validation.md. Keep this file
focused on current next steps; do not append chronological development diaries.

## Next milestone

Connect real Omarchy activity and appearance through the source service to the
existing iPhone app and phone-owned watch. Reuse relevant upstream collectors;
do not start the old desktop Bluetooth owner or install duplicate agent hooks.

The Omarchy machine is now running this checkout as the transient user service
`paceman-source.service`; the old `omarchy-watch.service` is stopped. The existing
private HTTPS route is reused. The prior Linux source database was migrated with
SQLite backup, preserving its source identity and paired client credential.
This service setup lasts for the current boot; it is not a permanent install.
Check it with `systemctl --user status paceman-source.service`. Do not start a
second source while testing the phone.

1. Build/install the updated phone app: earlier builds reject non-synthetic mode.
2. Connect the updated phone to the running Omarchy source over private HTTPS.
   Existing pairing works if it belongs to the migrated Linux source; otherwise
   generate a fresh invitation. See docs/omarchy-routing.md.
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
