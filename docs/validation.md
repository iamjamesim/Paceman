# Validation

This record separates implementation checks from physical-device evidence.
It describes the private prototype as of 2026-09-17, not a reliability guarantee.

## Automated checks

- 39 Python service/push/Omarchy tests passed on Linux: API authorization, invitation expiry and
  single use, persistence, SSE, scheduling, revocation, token updates, hint content,
  signing, retry/coalescing and delivery bookkeeping. Apple responses are mocked.
  Omarchy coverage includes the installed v0.2.0 companion script with fixture
  lifecycle/tool payloads, socket ingestion, authenticated HTTP/SSE, multiple
  sessions, delayed cleanup, restart behavior, and appearance-only alert suppression.
- Host C profile and sound tests passed against the imported watch source.
- A temporary source process successfully served an authenticated Omarchy
  snapshot with this desktop's Sakura Mochi palette, then removed its test socket
  on shutdown. This did not change the installed desktop bridge or HTTPS route.
- After the approved live switch, the installed companion script's fixture
  events passed through the running Paceman receiver and existing private HTTPS
  route: working → needs input → working → finished → session removed. Pairing
  and authenticated fetches succeeded with a temporary probe client, which was
  revoked afterward. This verifies the desktop route, not a phone/watch delivery.
  The migrated Linux source identity and original paired client were preserved.
- Prior iOS XCTest run passed 15 tests covering wire layout, ownership receipts,
  invitations, source metadata, push hints and presentation ordering/state.
- This Linux change adds an iOS test for accepting Omarchy mode while rejecting
  unknown modes and mismatched source identities. The updated iOS tests/build
  have not run here; Xcode is required on the Mac.
- iPhone app and widget built for simulator and device; signed build installed.
- Firmware sources and simulator C code were imported byte-for-byte from v0.6.1.
  A full ESP-IDF source build and LVGL rendering have not been rerun on this Mac.

## Physical-device evidence

- Source pairing, push registration, foreground APNs receipt and authenticated
  Tailscale fetch succeeded on an iPhone 16.
- In one locked-phone run, a callback occurred about 16 minutes 29 seconds after
  the last recorded background transition. Fetch completed approximately 2.4 seconds
  after event creation (separate clocks). The user confirmed receiving the alert
  without opening it, and the log had no intervening foreground/open event.
- That run did not confirm BLE delivery. It does not establish suspension timing,
  repeatability, cellular behavior or silent-push reliability.
- The ESP32 watch was cleanly flashed with the verified upstream v0.6.1 bundle;
  the flashing tool verified written hashes. The user subsequently confirmed
  phone pairing. Real source-to-watch rendering has not yet been verified.

## Remaining acceptance tests

- Live trusted-hook → private HTTPS → updated iPhone → physical watch routing.
  The adapter is implemented; fixture-driven integration does not establish this
  complete device path. See [the routing runbook](omarchy-routing.md).
- Physical watch rendering after foreground and push-triggered updates.
- Extended locking, cellular/roaming, Low Power Mode and Focus behavior.
- Bluetooth/source/VPN disconnect and recovery without re-pairing.
- Honest stale state across devices. The current legacy BLE activity packet does
  not give the watch an upstream freshness lease.
- Theme/appearance forwarding to the watch and visible widget refresh behavior.

An APNs 200 is server acceptance, not phone delivery. A notification is not proof
of background execution. A BLE write is not proof of visible rendering. Record
these stages separately in future tests. Keep raw device logs and identifiers
under ignored runtime storage, not in this document.
