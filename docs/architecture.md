# Architecture

Paceman connects agent workspaces to personal gear. Work remains in the source
agent environment; the hub presents current state and relays it to accessories.

```text
Workspace adapter (planned: Omarchy)
            │
            ▼
Private source service ── HTTPS snapshot / foreground SSE ──► iPhone ── BLE ──► watch
            │                                                  │
            └── optional APNs hint ──► bounded fetch attempt ────┘
                                                               └── App Group snapshot ──► widgets
```

## Source service

`service/hub.py` currently owns a synthetic source, SQLite persistence, single-use
pairing invitations, authenticated reads, revision ordering and push destinations.
It listens only on loopback. Tailscale Serve supplies private HTTPS. The future
Omarchy adapter should collect existing agent status and desktop appearance,
then supply the same snapshot contract without depending on a particular display.

`service/push.py` is an optional process beside that source. It sends a minimal
APNs hint; the phone fetches current data from its previously paired endpoint.
The hint never provides a fetch URL or credentials. Apple decides whether to grant
background runtime. SSE is useful in the foreground, not a suspension bypass.

## iPhone and widgets

`CompanionModel` coordinates state, fetching and delivery. `SourceClient` handles
the authenticated API. `WatchLink` handles accessory selection, ownership, BLE
packets and restoration. `CompanionHome` and `PresentationModel` present current
sessions and connection state; `ios/Shared/` defines shared widget storage.

The app has one feed. Workspace setup becomes a status card; watch setup becomes
a connection row. Settings contains widgets and developer tools. A valid source
palette is followed automatically. Widgets read shared snapshots and show their
age; WidgetKit schedules refreshes.

## Watch device package

`firmware/esp32-watch/` retains the upstream firmware/simulator/tools layout so
shared C rendering code and relative build paths remain coherent. Firmware owns
rendering, power, BLE bonding and persisted owner identity. The phone currently
uses the v1 profile and activity packets; newer upstream display/freshness packets
are available for future integration. Do not treat them as already forwarded.

The watch has one owner. A desktop disconnect does not transfer ownership.
The old standalone desktop installer/bar plugin is deliberately not included.

## Growth boundaries

Add workspace adapters under the source service and device-specific presentation
under their own packages. Share protocol definitions and fixtures, not UI code
across unrelated platforms. A second workspace or device should not require a
separate copy of pairing, state ordering or permission handling. Avoid introducing
a plugin framework until actual integrations demonstrate a need.
