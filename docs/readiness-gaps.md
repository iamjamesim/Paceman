# Known gaps

These are current product limits, not design requests. A successful source
snapshot, APNs response, phone fetch, BLE write and visible watch update are
separate observations. Supported claims require the relevant physical check.

## Before outside testers

- **Public push delivery:** The alpha uses an APNs signing key on each source
  workstation. A public build needs a key-safe relay with authenticated source
  events, destination registration and revocation, and abuse limits. Check
  production APNs acceptance, phone presentation and Apple Watch display
  separately.
- **Mac session accuracy:** An ephemeral CLI task remained Finished after its
  process exited. Test `SessionEnd` with real desktop, CLI and ChatGPT Work
  sessions; use supported lifecycle signals to fix missing cleanup. A desktop
  Computer Use approval remained Working because no Needs input hook reached
  Paceman. Do not infer approval from tool duration.
- **Clean installs:** Repeat Mac installation on a desktop-only Codex machine.
  The current allowance query can use the desktop app's bundled runtime, whose
  internal path may change. Run Omarchy's Codex desktop app through hook,
  process-owner, session-exit and allowance checks before claiming support.
- **Distribution:** Mac binaries need a distribution signing and notarization
  path; both desktop installers need clean install, update, pause, removal and
  recovery checks. Direct APNs and private Tailscale setup remain technical
  preview steps.

## Device and data checks

- Locked-phone custom-watch delivery needs a matrix for idle, reconnection,
  Focus, permission changes and multiple sources. Record source event → APNs →
  ANCS → phone fetch → BLE receipt → visible state for each case.
- The custom watch cannot yet expire active source activity locally after it
  loses the phone link. Firmware needs a stale/disconnected treatment and
  reconciliation on reconnect.
- Mac Codex allowance reached the phone and physical custom watch. Reset,
  unavailable and clean desktop-only cases remain untested. Quota-only updates
  wait for the next phone fetch; measure locked-phone freshness before changing
  that policy.
- Multiple Codex accounts have no shared account identity. The phone picks a
  recent source reading for display; it does not merge accounts.
- Source events have no retention limit. Add bounded retention without losing
  the current snapshot or push cursors.

Only Codex agent monitoring is implemented. Other providers shown in design
fixtures are examples, not supported integrations. The ESP32 watch is
experimental; iPhone and Apple Watch are the main receiving devices.
