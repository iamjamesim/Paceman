# System lifecycle map

This is the working map for reasoning about Paceman across restarts, sleep,
disconnects and stale data. It stays intentionally small; the linked documents
carry implementation detail.

## End-to-end shape

```text
agent event
    │
    ▼
Desktop sources ── authenticated snapshots ──► iPhone ── aggregate activity ──► watch
    │                                           │              BLE
    ├── visible APNs notification ──► iOS ── ANCS ───────────────────────► watch
    │                                      │                               │
    │                                      └── notification-sync request ──┘
    └── ActivityKit push ──► Live Activity / Dynamic Island

iPhone ── WeatherKit ──► phone weather cache ── profile ──► watch
```

The source owns agent truth. The phone is the authenticated hub and owns device
preferences. The watch renders the latest accepted state. APNs and ANCS wake the
path; the authenticated snapshot and BLE packets remain authoritative.

## Four independent questions

Do not reduce the system to one `connected` flag. For any screen or recovery path,
answer these separately:

1. **Relationship:** Which computers, phone and watch are still paired or authorized?
2. **Reachability:** Which source–phone links and phone–watch link are usable now?
3. **Freshness:** Which fields are current, historical or expired?
4. **Presentation:** Which surfaces should show or alert on the state?

A sleeping computer does not unpair the phone. A watch can be connected while the
computer is unavailable. A retained theme can remain valid while agent activity is
historical and an allowance has expired.

## State ownership

| State | Authority | Durable copies | When it changes or clears |
| --- | --- | --- | --- |
| Computer pairing and identity | Source + phone credential | Desktop SQLite; phone Keychain | Explicit removal, replacement or confirmed revocation |
| Agent activity and sessions | Source snapshot | Desktop SQLite; last-known phone snapshot | New source event; phone presentation becomes historical after its freshness lease |
| APNs destination and delivery cursor | Source | Desktop SQLite | Phone registration changes or client is removed |
| Watch ownership and identity | Phone + watch | Phone Keychain/UserDefaults; watch NVS | Explicit removal, owner change or factory reset |
| Watch preferences | Phone | Per-watch UserDefaults; accepted profile in watch NVS | User edit or watch removal |
| Watch activity | Latest delivered source event | Phone delivery bookkeeping; watch RAM | Next event, wearer clearing an attention state, or watch reboot |
| Theme | Source profile | Desktop snapshot, protected phone cache, watch NVS | New valid theme or explicit source removal |
| Allowance | Source profile | Desktop snapshot, protected phone cache, watch NVS | New reading; becomes unavailable after its recorded reset |
| Weather | Phone | Protected phone cache; watch NVS profile | Refresh, confirmed movement, preference change or expiry |
| Live Activity | Source event | ActivityKit system state | New event, stale date or lifecycle end |

Pending network requests, BLE writes, subscriptions and connection objects are
session state. They are rebuilt from durable identity and current authoritative
state; they are never treated as the relationship itself.

## Normal event path

1. A desktop event updates the source snapshot and advances its event identity.
2. The source sends a distinct visible APNs notification. iOS can present it and
   expose it to the watch through ANCS. A separate ActivityKit push updates the
   Live Activity without running the app.
3. The watch recognizes a Paceman ANCS event and requests current state over its
   encrypted notification-sync characteristic.
4. When iOS grants the phone execution, the phone fetches the authenticated current
   snapshot and writes the latest activity/profile over BLE.
5. Revisions and acknowledgements suppress stale or duplicate alerting. Recovery
   always converges on the latest snapshot; it does not replay an event history.

## Recovery scenarios

| Disruption | What the user keeps | Recovery |
| --- | --- | --- |
| Computer sleeps or network disappears | Pairing, theme, historical activity and valid cached allowance | Next foreground fetch, APNs event or watch request checks the source |
| Source restarts | Pairing and its stored snapshot | Omarchy reconciles live processes; Mac clears hook-only sessions until a new hook arrives |
| Phone is suspended or system-terminated | Protected snapshot, credentials, preferences and Bluetooth identity | APNs, Core Bluetooth restoration or foreground lifecycle restores execution |
| Watch leaves range or loses power | Pairing and accepted profile; a reboot does not show stale activity | Core Bluetooth reconnects; the handshake fetches and reconciles current state |
| APNs permission or notification sharing is off | Pairing and opportunistic foreground/BLE synchronization | User restores the disabled system permission; reliable background watch events depend on it |
| Weather refresh fails | Last observation with its original age | A later eligible refresh replaces it; failure never makes old data look new |
| Computer or watch is removed | Nothing from that relationship should remain active | A new pairing is required |

Recovery is driven by platform lifecycle events. Timers can refresh while the
process already has execution time, but correctness cannot depend on a polling
loop waking a suspended phone.

## Rules to preserve

- A transport failure never deletes pairing, preferences or last-known profile data.
- Stale activity is labeled as history and is not animated or forwarded as current.
- Each field expires by its own meaning; the whole snapshot is not erased together.
- Reconnection sends the latest authoritative state, not every missed transition.
- Device removal is the destructive boundary. Routine offline states recover automatically.
- UI reports each link independently and offers an action only when the user must act.

For implementation detail, use [component architecture](architecture.md),
[data ownership and expiry](data-lifecycle.md), [Bluetooth lifecycle](bluetooth-lifecycle.md),
[wire contracts](protocol.md), and [home-screen state semantics](home-screen-design.md).
