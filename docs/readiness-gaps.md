# Known limitations

Paceman is a developer alpha. Mac Codex desktop and CLI hooks and the Omarchy Codex CLI companion have been exercised on development devices. Only Codex activity is implemented. The ESP32 watch is experimental; iPhone and Apple Watch are the main receiving devices.

- **Mac activity:** A short-lived CLI task has remained Finished after exit when `SessionEnd` did not arrive. A desktop Computer Use approval has remained Working because no Needs input hook reached Paceman. Hook presence alone does not prove a hook was trusted or delivered. The Mac lacks Omarchy's process-ownership check.
- **Omarchy desktop app:** The current adapter has been exercised with Codex CLI, not the Codex desktop app on Omarchy. Desktop hook delivery, process ownership, session exit, and allowance remain unverified there.
- **Background delivery:** Connected locked-phone updates have reached the custom watch, but unattended reconnection, long idle periods, Focus, permission changes, and multiple-source combinations have not all passed physical checks. APNs acceptance is not evidence of visible phone or watch delivery.
- **Custom-watch freshness:** The firmware cannot yet expire active source activity locally after losing the phone link. It reconciles when the phone reconnects.
- **Codex allowance:** A reading can reach the phone and custom watch, but reset, unavailable, and desktop-only Mac cases need more validation. Multiple Codex accounts have no shared identity; the phone displays one recent source reading rather than merging accounts. Allowance-only changes wait for a later phone fetch.
- **Distribution:** The current key-safe APNs relay is limited to a hand-enrolled internal pilot. Open TestFlight requires self-service source and device registration, a persistent relay-side source-to-destination permission registry, and automatic revocation before hosting or physical-device checks. The legacy direct sender still exists for owner-controlled alpha installs. Mac binaries also need Developer ID signing and notarization. The current installers are source-based developer paths.
- **Source retention:** The source events table has no retention limit. A future bound must preserve the current snapshot and push cursors.

See [architecture](architecture.md), [push delivery](push-delivery.md), and [data lifecycle](data-lifecycle.md) for the behavior behind these limits.
