# Product gaps after the two-computer alpha pass

Reviewed 2026-09-24. A working iPhone screen or accepted APNs request does not
establish the same behavior on another person's Mac, account, or watch.

## Close for daily alpha use

| Gap | Current evidence | Acceptance before calling it done |
| --- | --- | --- |
| Mac Codex allowance | The updated Mac source and iPhone app are installed on the paired devices. The Mac snapshot has a fresh allowance, a phone fetch followed it, and the user confirmed a current CODEX allowance on the physical watch. Queries through both the separate CLI and this Mac's desktop-bundled runtime succeeded. | Check reset and unavailable states, and repeat on a clean desktop-only Mac. |
| Allowance delivery timing | Quota-only changes advance source presentation revision but do not send agent attention alerts or independently wake the suspended phone. The watch catches up on the next phone fetch and profile write. | Measure normal locked-phone quota freshness; decide whether an opportunistic quiet sync is needed without promising a fixed cadence. |
| Mac session exit accuracy | Hooks report state transitions, but an ephemeral CLI task remained Finished after its process exited in the installation check. The Mac has no process proof comparable to Omarchy. | Exercise `SessionEnd` in Codex desktop, CLI, and ChatGPT Work with real tasks; fix missing cleanup using supported lifecycle signals, without guessing from elapsed time. |
| Locked-phone watch delivery | Several connected/background ANCS updates worked, but idle, reconnection, Focus, permission changes, and multiple-source combinations are not a complete hardware matrix. | Record source event → APNs → ANCS → phone fetch → BLE receipt → visible watch state for each case in `notification-api-review.md`. |
| Watch activity freshness | Phone and Live Activity distinguish current from historical source state. The custom watch cannot yet expire an active source state locally when the connection disappears. | Firmware shows a stale or disconnected treatment after source freshness expires, then reconciles on reconnect. |

## Decide before external testers or launch

| Gap | Decision or work |
| --- | --- |
| Multiple Codex accounts | Source allowance has no account identity. The phone now prefers a recent connected reading, then recent paired data, then cached history. This is a display rule, not account-level merging. Decide whether to label the source or let the user select one account when testers use different accounts. |
| Desktop-only Codex installations | The desktop app on this Mac bundles a callable Codex runtime, so a separate CLI is not required here. Its internal executable path is not a documented packaging contract. Check clean installs and app updates; report unknown if the runtime cannot be found or queried. |
| Agent/provider coverage | Real source monitoring is Codex-only. Other agent examples in previews are fixtures, not integrations. State Codex-only scope clearly for the first release, or add adapters with their own identity and lifecycle tests. |
| Omarchy project label | Mac hooks can send a short path-free workspace label; Omarchy sessions currently send provider and state only. Test whether users need project distinction before adding metadata collection. |
| Public push delivery | Direct APNs signing keys on each workstation are an alpha setup. A public distribution needs a relay, registration/revocation, and abuse controls without sending agent content. |
| Distribution and maintenance | Mac packaging/update/signing and notarization, broader machine support, firmware recovery, and bounded source event retention remain release work. |

No phone or Live Activity layout change is implied by this list. The phone owns
themes and weather; those are not missing Mac payload fields. A quota reading is
useful on the watch, but quota changes are presentation updates and are not a
reason to send agent attention alerts.
