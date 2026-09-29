# Architecture

Paceman connects agent workspaces to personal gear. Work remains in the source
agent environment; the hub presents current state and relays it to accessories.

```text
Omarchy events, Mac Codex hooks (or synthetic test source)
    │
    ▼
Private source service ── HTTPS snapshot ──► iPhone ── BLE ──► watch
    │                                                        ▲
    ├── APNs notification ──► iOS Notification Center ── ANCS ─┘
    └── ActivityKit push ──► Live Activity / Dynamic Island
```

## Source service

`service/hub.py` owns source snapshots, SQLite persistence, single-use
pairing invitations, installation metadata, per-client contact, authenticated reads,
self-revocation, revision ordering and push destinations. Local desktop revocation
and authenticated phone removal delete the credential, identity and push destination
together. Installation claims alone cannot replace another credential.
It listens only on loopback. Tailscale Serve supplies private HTTPS.
`service/omarchy.py` receives the existing desktop companion's local `agent-event`
protocol without starting a Bluetooth owner. Synthetic mode supports isolated tests.
See [Omarchy installation](desktop.md) for the live route.
Activity and allowance changes both advance snapshot revisions; allowance-only
changes retain the activity event ID and do not send activity alerts.
`service/macos.py` receives reduced Codex lifecycle events from a trusted local
hook script. It shares the source API and credentials but uses hook-derived
session state rather than Linux process verification.

`service/push.py` is an optional process beside the source. Ordinary APNs alerts
carry a minimal hint so the phone can fetch from its paired endpoint; ActivityKit
pushes carry a separate display copy for Live Activities. Neither includes a
source URL or credential. Apple controls background execution, and custom-watch
requests use Core Bluetooth. See the [communication protocol](protocol.md).

## Desktop package

`desktop/` supplies a per-user installer, control command and Omarchy bar panel.
The installed systemd user service starts at login. `service/status.py` publishes
an atomic, private runtime status file with a heartbeat, aggregate activity,
per-state session counts and last authenticated client fetch. The panel expires a missing heartbeat and never
claims Bluetooth or watch delivery status that the phone has not reported.
The source runs independently of the shell. On Linux, `service/processes.py`
binds sessions to the Codex ancestor of the kernel-identified hook sender, then
reconciles PID/start-time/boot identities on startup and about once a second.
Activity and liveness are separate; a living process can remain Finished or Idle. See [desktop setup](desktop.md).
`macos/` supplies an arm64 SwiftUI menu-bar app, a per-user LaunchAgent, and an
agent-led installer. See [Mac setup](macos.md).

## iPhone and Live Activities

`CompanionModel` coordinates state, fetching and delivery. `SourceClient` handles
the authenticated API. `WatchLink` handles accessory selection, ownership, BLE
packets and restoration. `CompanionHome` and `PresentationModel` present current
sessions and connection state; `ios/Shared/` defines theme and Live Activity types.

The app shows independently paired computer activity cards. Workspace setup becomes a status card; watch setup becomes
a connection row. Settings contains Appearance, notifications, and developer tools.
The phone owns the selected theme family independently of paired computers. The
WidgetKit extension reads it from shared App Group preferences for Live Activities.
There are no Home Screen or Lock Screen status widgets.

## Watch device package

`firmware/esp32-watch/` retains the upstream firmware/simulator/tools layout so
shared C rendering code and relative build paths remain coherent. Firmware owns
rendering, power, BLE bonding and persisted owner identity. The phone negotiates
profile v1–v5 for time, the phone-selected palette, weather, watch settings and source-reported Codex
allowance, and still uses activity v1. The accepted profile survives watch
restarts; agent activity remains an in-memory event state.

The watch has one owner. A desktop disconnect does not transfer ownership.
The old standalone desktop installer/bar plugin is deliberately not included.
