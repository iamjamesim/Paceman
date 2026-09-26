# Monitoring delivery and attention: API review

September 21, 2026. Design recommendation, not a claim of hardware acceptance.
State-based notification presentation and conditional recovery are implemented locally. Provisional
authorization and the hardware matrix below remain unimplemented or unverified
as indicated. Live Activity alert routing was implemented in the source on
September 25; its phone sound and haptic behavior still needs physical testing.

## Current implementation scope

Prioritize custom-watch delivery. Keep the Live Activity / Apple Watch mapping as follow-up architecture,
not the next implementation milestone. Preserve existing phone monitoring support.
The immediate acceptance target is quiet, prompt agent-state delivery to the custom
watch while the phone remains locked, including prolonged idle and reconnection,
with independent watch alerts and actionable permission recovery.

Keep source state, revision/freshness, device capabilities and alert preferences
separate from the transport.

The EU-only Accessory Notifications path is a potential future adapter, not a
global delivery dependency. Its regional availability follows Apple's rollout of
DMA interoperability measures; the DMA requires access in the EU, not exclusion
elsewhere. See the [Commission's connected-device decision summary](https://digital-markets-act.ec.europa.eu/commission-provides-guidance-under-digital-markets-act-facilitate-development-innovative-products-2025-03-19_en).

## Product contract

Show current work at a glance. Interrupt only for meaningful transitions when
the user wants alerts. Preserve useful event history. If delivery is unavailable,
show the last known state as stale rather than silently treating it as current.
Configuration, Bluetooth connection, APNs acceptance and successful rendering are
four different facts. No Apple API supplies an unconditional end-to-end deadline.

## API choices

| Mechanism | Use | Boundary |
| --- | --- | --- |
| ActivityKit APNs | Live status on Lock Screen, Dynamic Island and Apple Watch Smart Stack | Separate token and lifecycle; normal updates do not imply phone app runtime; update budgets and user settings apply |
| ActivityKit alert payload | Optional attention for a Live Activity update | Avoid a second interrupting ordinary notification for the same event |
| Alert-type APNs with passive interruption level | Quiet event history and custom-watch ANCS trigger | Still a user-visible Notification Center entry; Focus/Summary and permissions matter |
| Active alert-type APNs | Attention when no Live Activity is responsible for alerting | Sound is optional; system presentation settings remain authoritative |
| Provisional authorization | Trial quiet notifications during first-time accessory setup | Does not bypass denial; later prominent authorization is separate; ANCS behavior needs hardware validation |
| ANCS + Core Bluetooth restoration | Custom-watch event notification and existing snapshot request/response | Validate reconnect and background fetch separately; no periodic probe |
| WidgetKit push + timeline | Secondary phone widget / watch complication freshness where available | Push reloads are budgeted and opportunistic, not every-transition delivery |
| Background push / BGAppRefresh | Opportunistic reconciliation | Never the correctness dependency for prompt watch delivery |
| Notification service extension | Content decryption/enrichment if needed later | Not a main-app wake API or an established BLE relay; do not use it to hide notifications |

Transport priority, interruption level and sound are separate controls. APNs
priority 10 does not mean an audible notification. Passive means noninterrupting
presentation, not guaranteed immediate delivery. Omitting sound alone does not
make an active notification passive.

## Recommended policy

One versioned source event feeds all enabled destinations. Share generation,
revision, event identity, freshness and state semantics. Use platform-specific
delivery adapters, not separate business logic or app-owned background timers.
Retries reuse identity; distinct transitions retain distinct notification entries.
Reject older snapshots. Coalesce state snapshots without replaying old attention
alerts after reconnection. Scope alert deduplication by source/session/transition.

Working/Idle ordinary notifications are passive. Needs input/Failed/Finished
ordinary notifications request active presentation and sound. Lock Screen,
banners, sound and Mac mirroring for ordinary notifications remain configured in
iOS Settings. Live Activity alerts use their own custom sounds for Working,
Needs input, Failed, and Finished. Keep watch Status sounds as a per-watch preference. Do not automatically
mute the phone because a watch happens to be connected: connection does not prove
the person received an alert.

Watch setup recommends Notification Center on and Lock Screen, Banners, Sounds and
Show on Mac off, with a deep link to Paceman's notification settings. This makes
watch transport reliable and phone presentation quiet without duplicating iOS
controls inside Paceman. Recovery links appear when a delivery requirement is off.

Live Activities remain independently optional. For phone-only monitoring, update
the Live Activity for progress and use its alert mechanism for attention when
selected; otherwise use ordinary notifications. Do not infer presentation from an
APNs 200 response. Define lifecycle registration/expiry before allowing the server
to choose the alert destination; use one destination per event, not a timed
duplicate alert fallback. Dismissal while the phone is suspended is a validation
case, not something to solve with a guessed delivery acknowledgment.

With a custom watch enabled, ordinary Notification Center events are still needed
for ANCS even while the Live Activity exists. These can be passive when the Live
Activity owns phone attention. This duplicates presentation/history across
surfaces, but must not duplicate phone alerts. It is a real cost of this accessory
path, not something provisional authorization removes.

ActivityKit priorities: propose 5 for routine progress and 10 for attention-worthy
transitions, independent of whether an alert is requested. Observe frequent-update
authorization if adopted. Use push-to-start for real new work, not an empty
permanent monitoring activity. Ending and staleness are distinct: missing contact
does not prove no active session.

Apple Watch first uses the system Live Activity Smart Stack presentation, with a
small supplemental layout. A native watch app can add interaction later. A
complication is a budgeted glance, not the primary live-status contract.

## Setup and recovery

Keep watch controls in their established location. A conditional actionable notice
under watch status says Background updates need notifications and opens the one
missing recovery step. Do not repeat permanent warnings in the preferences.
The separate Notifications section shows delivery recovery and the recommended
iPhone system settings. Pairing asks only for the next missing requirement, then
shows the same recommendation and deep link. Never reset existing permission.

Provisional setup is a candidate for first-time watch users, not an immediate
replacement for existing authorization. Test before selecting it. An explicit
request for notifications can request full authorization or lead to Settings based
on actual authorization status. Notification permission denied must not disable
an independently allowed Live Activity.

## Newer APIs and version limits

The app currently targets iOS 18. WidgetKit push is a newer OS capability and must
be availability-gated. Modern WidgetKit budget guidance is more appropriate than
treating the old ClockKit 50-push/day figure as a universal watch limit.

AccessoryNotifications/AccessoryTransportExtension provide a purpose-built newer
forwarding path, but customer availability is restricted to iPhones in the EU
with an EU-region Apple Account. Do not make a global product depend on it.

iOS 26 Core Bluetooth Live Activity support improves Bluetooth background
privileges; it does not document an unrestricted remote-network execution loop.
TN3115 also changes restoration eligibility for certain user actions with
AccessorySetupKit. Paceman already uses AccessorySetupKit: test force-quit and
Bluetooth controls on supported OS versions rather than copying an absolute old
force-quit rule into troubleshooting.

## Next evidence before implementation

1. Existing authorization: locked phone, all states passive, no sound. Correlate
   source event, ANCS arrival, BLE request, phone snapshot and watch revision.
2. Fresh provisional authorization: repeat; check history, no phone interruption,
   and independent watch alerts. Do not reset the user's main installation merely
   to obtain a fresh permission state.
3. Repeat after hours idle and out-of-range reconnect, then Focus and Scheduled
   Summary separately. Record delays as well as losses. Compare with active
   notifications without sound to isolate interruption-level effects.
4. Revocation, sharing disabled, Live Activities disabled/dismissed, and source
   offline: verify targeted recovery and stale states without false success.
5. Apple Watch Smart Stack and attention: confirm presentation and routing on real
   hardware. Simulator rendering is not delivery acceptance.

Seven prior connected/background ANCS updates are evidence for that specific
configuration only. The above matrix has not been executed. If passive/provisional
delivery cannot meet the product's latency expectations, document the boundary;
do not conceal it with aggressive timers or inappropriate interruption levels.

## Apple references

- [Notification authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [Interruption levels and Focus/Summary](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)
- [ActivityKit push lifecycle and priorities](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- [Live Activity presentation and alerts](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Live Activities on Apple Watch](https://developer.apple.com/videos/play/wwdc2024/10068/)
- [WidgetKit pushes and budgets](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)
- [ANCS](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html)
- [Bluetooth restoration rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
- [Core Bluetooth current capabilities](https://developer.apple.com/documentation/corebluetooth)
- [Accessory Notifications and regional availability](https://developer.apple.com/documentation/accessorynotifications)
- [Notification service extension contract](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)
