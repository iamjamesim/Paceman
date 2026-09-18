# Prototype contract v1

All remote paths require TLS from Tailscale Serve. The Python listener binds
only to 127.0.0.1. This is a private development service, not an internet-facing
production server. Limit tailnet access to the devices participating in the test.

`POST /v1/pair`: JSON `{ "invitation": "single-use secret" }`. Returns schema,
sourceID, clientID, and credential. Invalid/expired/used invitations return 401;
invalid bodies 400; excessive attempts 429. Invitation expiry is five minutes.

`GET /v1/snapshot`: `Authorization: Bearer CREDENTIAL`. Returns:

```json
{
  "schema": 1,
  "sourceID": "persistent UUID",
  "generation": "persistent UUID for this database",
  "revision": 2,
  "sourceName": "Transport test",
  "mode": "synthetic",
  "observedAt": 1790000000.0,
  "changedAt": 1789999998.0,
  "freshFor": 30,
  "state": "working",
  "eventID": "2",
  "sessions": [{"id": "test-session", "provider": "fixture", "state": "working"}]
}
```

States: idle, working, needs_input, finished. GET does not mutate event identity
or acknowledge attention. `observedAt` is the source's successful snapshot time;
`changedAt` stays fixed for the same event. Deleting/replacing the database creates
a new source identity and requires new pairing. Simple process restart does not.

`mode` is `synthetic` or `omarchy`. Live Omarchy snapshots use the same API and
pairing contract. `revision` advances for activity or appearance changes; `eventID`
and `changedAt` advance only for activity changes. They need not equal the latest
snapshot revision. Appearance updates therefore cannot replay a watch alert.
The source's `observedAt` establishes service liveness. Omarchy sources with
`sessionLiveness: "process"` additionally verify each listed session's owning
Codex process locally. Finished and Idle sessions can remain open. PID/start-time/
boot metadata is never exported. Clients can ignore this optional marker.
See [routing semantics and recovery limits](omarchy-routing.md).

`GET /v1/events`: same authorization, `text/event-stream`. Each `data:` line
contains a full snapshot. Emit immediately, on revision change, and every 15
seconds to establish source liveness. Event scheduling runs independently in
the server loop. Revoked clients are disconnected. An SSE stream is an
experimental transport, not an iOS background execution mechanism.

Watch encoding matches the existing Omarchy v0.6.1 protocol: 36-byte time/owner
profile and 14-byte activity snapshot. Integers are little endian. The phone
assigns and persists monotonic watch revisions; source IDs and revisions do not
become Bluetooth identities. Repeated source events reuse delivered revisions,
and acknowledged events are not re-alerted. A crash between a physical write
and saving its delivery result can still cause a duplicate; no exactly-once
guarantee is made.

The watch has no local upstream freshness lease in this protocol. Do not
silently repurpose existing packet fields. Add negotiated protocol support
before treating this as daily monitoring. Source session state and local watch
acknowledgement remain separate in the Omarchy adapter.
# Direct push destination extension

The optional direct-APNs probe adds `/v1/push` to this test source. All three
methods require the same paired `Authorization: Bearer …` credential as snapshot
reads. The server derives ownership from that credential; callers cannot select
another client ID. These are private Tailscale endpoints, not a public relay API.

- `POST`: `{ "deviceToken": "lowercase hex", "environment": "development" | "production", "mode": "alert" | "background" }`.
  Validated payloads upsert that client's destination. Re-registering an unchanged
  token preserves pending work and retry state. A changed token or mode starts
  after the current event, avoiding historical alert replay.
- `GET`: returns `registered`, and when present `environment`, `mode`,
  `lastResult`, `lastAPNsID`. Never returns a destination token.
- `DELETE`: removes only this client's push destination. Revoking the client also
  removes its destination. Requests with invalid/revoked credentials return 401.

The direct sender adds a `companion` hint alongside `aps`, with `schema: 1`,
`sourceID`, `generation`, `eventID`, and integer `revision`. The phone validates
the hint against its pairing, then fetches `/v1/snapshot` from its stored source.
The push does not control the fetch URL, credentials, or resulting watch state.
See [direct push test](direct-push-test.md) for modes, throttling, and limitations.

## Optional phone presentation metadata

The iPhone can display `sessions` entries containing `id`, `provider`, and `state`,
with optional `name` and `project` strings. Synthetic mode emits a fixture session;
the Omarchy adapter emits opaque session IDs, providers and lifecycle states.
It does not read task names, projects or conversation content from the companion.

A snapshot may also carry a resolved appearance object:

```json
"appearance": {
  "id": "omarchy-current",
  "name": "Solitude",
  "background": "101315",
  "foreground": "CACCCC",
  "accent": "A4B4BB",
  "monospaced": true
}
```

Colors are six-digit RGB hex, optionally prefixed with `#`. `monospaced` selects
the bundled JetBrains Mono family; arbitrary remote fonts/assets are not loaded.
Missing or invalid optional presentation metadata is ignored without discarding
a valid core snapshot. The app uses its neutral appearance until a valid source appearance
is supplied. There is no user-facing local theme picker. A source increments
its revision when session content changes. The Omarchy collector supplies live
appearance metadata using the desktop bar overrides and accent contrast fallback.
BLE theme forwarding remains unimplemented.
