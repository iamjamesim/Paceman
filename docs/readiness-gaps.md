# Known behavior and device checks

Paceman currently tracks Codex activity. The Mac Codex desktop and CLI hooks and the separate Omarchy Codex CLI companion have been exercised on development devices. The ESP32 watch is experimental; the iPhone and Apple Watch are the main receiving devices.

## Behavior limits

- **Mac sessions:** Mac activity depends on reviewed hooks and cannot independently verify that the sending Codex process is still alive, as Omarchy can. If `SessionEnd` is missing, a completed CLI session can leave a Finished row for up to ten minutes. An observed desktop Computer Use approval remained Working because no Needs input hook reached Paceman. An async question can clear early when an unrelated user message arrives; see [Mac hooks](macos.md).
- **ESP32 activity freshness:** Weather and allowance expire locally, but the activity packet has no source-freshness lease. If the phone link is lost while an agent is active, the watch can keep showing that state until it reconnects and receives the current aggregate. Reboot clears activity from RAM.
- **Allowance aggregation:** Separate Codex accounts have no shared identity. The phone selects one recent source reading rather than combining accounts. An allowance-only change advances the source snapshot but does not send an ordinary activity notification, so the iPhone sees it on its next fetch. The Apple Watch has a separate allowance push path; see [push delivery](push-delivery.md).

## Checks still requiring devices

| Path | Check | Already observed |
| --- | --- | --- |
| Mac hooks | Review and trust the installed hook rows, then confirm a fresh Codex event reaches the source. Exercise short CLI sessions, desktop approvals, and allowance reset or unavailable states. | Mac desktop and CLI hooks have produced activity. Synthetic lifecycle and allowance tests pass. |
| Omarchy hooks | In a fresh Omarchy Codex CLI session, verify installation and hook review, process ownership, session exit, and allowance. Check Codex desktop hooks and ESP32 delivery separately if those surfaces are intended to be supported there. | The separate CLI companion has run on Omarchy. The bundled hook and async-question path pass synthetic tests on Mac. |
| Locked iPhone and ESP32 watch | Confirm delivery while already connected, then separately test unattended reconnection after Bluetooth loss or iOS suspension. Exercise long idle periods, Focus and notification-permission changes, and two active computers. | A connected watch received updates while the phone was locked. |
| Allowance across receivers | Check reset and unavailable readings on the iPhone and ESP32 watch. On a physical Apple Watch, confirm a changed reading, reset and unavailable state, including a Mac desktop-only source. | A reading reached the iPhone and ESP32 watch. Apple Watch push timing and payloads have automated coverage; APNs acceptance alone does not prove watchOS processed them. |
| Signed iPhone and relay | On a signed physical iPhone, pair a new source through App Attest, receive a new notification, and verify phone/source removal and relay revocation. | An earlier TestFlight phone paired, received updates, and displayed a push. Temporary sources passed live cross-source denial, unbinding, and durable revocation checks without a push. App Attest enrollment has local tests, not this device check. |

The [relay guide](push-relay.md) tracks deployment and signing steps. [Architecture](architecture.md) and [data lifecycle](data-lifecycle.md) explain the state behind these limits.
