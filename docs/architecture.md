# Architecture

Each Mac or Omarchy computer runs an independent source. The source turns local Codex events into a current snapshot; the iPhone pairs with each source and owns presentation and the experimental watch's Bluetooth connection. Agent prompts, replies and tool arguments remain on the computer.

```text
Codex hooks / Omarchy event adapter
                 │
                 ▼
          Source + SQLite ── private HTTPS snapshot ──► iPhone ── BLE ──► ESP32 watch
                 │                                         ▲                 ▲
                 └── authenticated relay ── APNs ──► iOS Notification Center ── ANCS ─────┘
                                       ├── ActivityKit ──► iPhone Live Activity
                                       └── allowance ──► Apple Watch app
```

## Computer source

`service/hub.py` owns source identity, SQLite state, single-use pairing invitations, client credentials, authenticated snapshots, revisions, client revocation and push destinations. It binds to loopback; Tailscale Serve supplies private HTTPS. Removing a paired client deletes its credential and push destinations together. An installation ID alone cannot replace an existing credential.

The two event adapters feed the same source contract:

| Platform | Event input | Session liveness |
| --- | --- | --- |
| Mac | `service/macos.py` receives reduced lifecycle events from reviewed Codex hooks. | Hook-observed; sessions clear on source restart. |
| Omarchy | `service/omarchy.py` receives the Codex companion's local event socket. | `service/processes.py` verifies the sending Codex process and reconciles its identity after restart. |

Activity and allowance changes advance snapshot revisions. Allowance-only changes keep the activity event ID and do not send an activity alert. `service/status.py` publishes a private runtime heartbeat for the desktop panels; phone contact means an authenticated fetch, not watch delivery.

`service/push.py` is an optional push worker beside the source. It reads registered destinations from source SQLite and sends through `service/relay.py` with a source-specific credential; the relay alone holds the APNs key for tester setups. Ordinary notifications carry a fetch hint, while ActivityKit pushes carry an expiring display copy. Neither contains a source URL or paired-phone credential. See [push delivery](push-delivery.md) and the [wire protocol](protocol.md).

## Phone and watches

`SourceClient` reads each paired source using its stored credential. `CompanionModel` coordinates fetching, source state and delivery. The iPhone retains a last-known snapshot per source but marks expired activity as historical. It owns the selected theme and chooses one fresh aggregate for the ESP32 watch. The Live Activity extension reads shared presentation preferences; no Home Screen or Lock Screen status widget is shipped.

`WatchLink` owns ESP32 accessory selection, encrypted BLE packets and Core Bluetooth restoration. The watch owns rendering, its bond and owner ID, and the last accepted profile in NVS; current agent activity stays in RAM. A source disconnection does not change watch ownership. The iPhone negotiates profile v1–v5 and activity v1. See [Bluetooth lifecycle](bluetooth-lifecycle.md), [data lifecycle](data-lifecycle.md) and the [BLE protocol](protocol.md#iphone-and-custom-watch-ble).

The Apple Watch app receives optional Codex allowance updates through its own background push path and refreshes complications. It does not share the ESP32 Bluetooth route.
