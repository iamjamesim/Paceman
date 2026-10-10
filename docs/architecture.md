# Architecture

Each paired computer reports its own agent activity. Mac and Omarchy support Codex and Claude Code. The iPhone fetches that status over private HTTPS, presents each computer separately, and forwards current activity to compatible Bluetooth accessories. Current activity monitoring does not transmit prompts, agent replies, or tool arguments.

```text
       Reviewed agent hooks
                 │
                 ▼
          Source + SQLite ── private HTTPS snapshot ──► iPhone ── BLE ──► accessories
                 │                                         ▲                 ▲
                 └── authenticated relay ── APNs ──► iOS Notification Center ── ANCS ─────┘
                                       ├── ActivityKit ──► iPhone Live Activity
                                       └── Codex usage ────► Apple Watch app
```

## From agents to the phone

The computer's source listens to reviewed agent hooks, records current activity in SQLite, and serves authenticated snapshots. It binds to loopback; Tailscale Serve supplies private HTTPS. Pairing creates a credential for that phone. Removing the phone revokes its credential and push destinations together.

Mac and Omarchy differ in how they know a session is still running:

| Platform | Event input | Session liveness |
| --- | --- | --- |
| Mac | Reviewed Codex and Claude Code hooks. | Hook-observed; sessions clear on source restart. |
| Omarchy | Selected Codex and Claude Code hooks on a local socket. | Verifies the sending agent process and reconciles live sessions and Claude attention after restart. |

Both treat a completed turn as Finished. Codex rejects late turn events; Claude rejects old prompt callbacks and permits a new tool start when a Stop hook continues the same turn. Activity and allowance changes advance the snapshot revision, but allowance alone does not create an activity alert.

The iPhone keeps a last-known snapshot per computer. The session list, Live Activities and Pebble cards share a bounded five-minute observation lease; expired activity appears as history and is not forwarded as a new alert. Connection freshness follows the shorter snapshot lease. Phone contact means an authenticated fetch, not watch delivery.

## When the phone is asleep

When configured, the source sends notifications through the relay, which holds the APNs key and checks both source and phone credentials. An ordinary push hints that the iPhone should fetch current state; ActivityKit receives an expiring display copy that can update a Live Activity without running the app. See [push delivery](push-delivery.md).

## Watches

The iPhone maintains independent Bluetooth connections to each paired accessory and chooses activity from fresh computers. The watch retains its owner bond and profile, accepts data only from the authenticated owner, and keeps current activity in RAM. Reconnection sends current state rather than replaying missed events. See [Bluetooth lifecycle](../firmware/esp32-watch/CONNECTION.md) and [data lifecycle](data-lifecycle.md).

Usage is Codex-only and assumes one Codex account across computers. The phone
prefers a recent reading from a connected computer, then recent cached usage,
then older cached usage, in pairing order. Windows come from one computer;
accounts are not combined. Claude Code contributes activity only.

Apple Watch registers for direct background pushes from every paired computer,
so one computer going offline does not require the phone to switch sources.
The Watch caches each computer separately, chooses the newest available Codex
reading by its quota observation time, and shows its most constrained unexpired
window in Codex Limit and Codex Reset. Older or empty data from another computer
cannot erase that reading.

WatchConnectivity also supplies the paired-computer list and cached readings.
Apple Watch delivery is independent of accessory Bluetooth. Exact fields and
compatibility are in the [protocol](protocol.md); freshness and clearing rules
are in [data lifecycle](data-lifecycle.md).
