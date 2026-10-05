# Architecture

Each paired computer reports its own agent activity. Mac supports Codex and Claude Code; Omarchy currently supports Codex. The iPhone fetches that status over private HTTPS, presents each computer separately, and sends one current view to the ESP32 watch. Prompts, replies, and tool arguments stay on the computer.

```text
       Reviewed agent hooks
                 │
                 ▼
          Source + SQLite ── private HTTPS snapshot ──► iPhone ── BLE ──► ESP32 watch
                 │                                         ▲                 ▲
                 └── authenticated relay ── APNs ──► iOS Notification Center ── ANCS ─────┘
                                       ├── ActivityKit ──► iPhone Live Activity
                                       └── selected usage ──► Apple Watch app
```

## From agents to the phone

The computer's source listens to reviewed agent hooks, records current activity in SQLite, and serves authenticated snapshots. It binds to loopback; Tailscale Serve supplies private HTTPS. Pairing creates a credential for that phone. Removing the phone revokes its credential and push destinations together.

Mac and Omarchy differ in how they know a session is still running:

| Platform | Event input | Session liveness |
| --- | --- | --- |
| Mac | Reviewed Codex and Claude Code hooks. | Hook-observed; sessions clear on source restart. |
| Omarchy | Reviewed Codex hooks on a local socket. | Verifies the sending Codex process and reconciles after restart. |

Both treat a completed turn as Finished. Codex rejects late turn events; Claude rejects old prompt callbacks and permits a new tool start when a Stop hook continues the same turn. Activity and allowance changes advance the snapshot revision, but allowance alone does not create an activity alert.

The iPhone keeps a last-known snapshot per computer. Old activity can appear as history but is not forwarded as current. Phone contact means an authenticated fetch, not watch delivery.

## When the phone is asleep

When configured, the source sends notifications through the relay, which holds the APNs key and checks both source and phone credentials. An ordinary push hints that the iPhone should fetch current state; ActivityKit receives an expiring display copy that can update a Live Activity without running the app. See [push delivery](push-delivery.md).

## Watches

The iPhone owns the ESP32 watch's Bluetooth connection and chooses activity from fresh computers. The watch retains its bond, owner, and profile, but keeps current activity only in RAM. Reconnection sends current state rather than replaying missed events. See [Bluetooth lifecycle](../firmware/esp32-watch/CONNECTION.md) and [data lifecycle](data-lifecycle.md).

The Mac retains usage windows independently for Codex and Claude. The phone shows both; its Watch usage setting pins the provider for compact watch displays without changing activity or alerts. Usage stays with the first paired computer; accounts from separate computers are never combined.

When configured, the Apple Watch app receives the selected provider's usage through its own background push path and refreshes its complications. Foreground WatchConnectivity messages can supply both providers; a source identity and selection revision reject outdated pushes. ESP32 profile v6 also carries the selected provider. Older firmware displays unavailable when Claude is selected. Apple Watch does not use the ESP32 Bluetooth route. Exact fields and versions are in the [protocol](protocol.md).

See [Claude support and acceptance testing](claude-support.md) for event limitations, sign-in behavior and unverified hardware checks.
