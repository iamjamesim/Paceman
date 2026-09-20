# Prototype contract v1

All remote paths require TLS from Tailscale Serve. The Python listener binds
only to 127.0.0.1. This is a private development service, not an internet-facing
production server. Limit tailnet access to the devices participating in the test.

`POST /v1/pair`: JSON `{ "invitation": "single-use secret", "device": {
"installationID": "UUID", "name": "Alex’s iPhone", "platform": "ios" } }`.
Returns schema, sourceID, clientID, credential, and `clientManagement: 1`.
Invalid/expired/used invitations return 401; invalid bodies 400; excessive attempts
429. Invitation expiry is five minutes. Older clients may omit `device`; their
credentials remain explicitly unidentified.

Installation IDs are claims, not credentials. To re-pair an existing installation,
include its current `Authorization: Bearer CREDENTIAL` and a fresh invitation.
The source rotates the credential in place, keeps the client ID and pairing date,
clears its old push registration and contact time, and closes old event streams.
The phone must register push again. A claimed installation already owned by a
different credential returns 409 without consuming the invitation. Matching device
names never cause a merge. A revoked installation can pair afresh with a new code.

`POST /v1/client`: authenticated JSON `{ "device": { ... } }` identifies the caller's
existing credential or updates its reported name. Returns `clientManagement: 1`.
It cannot adopt another credential's installation ID or change an established ID;
conflicts return 409. Names are plain text, 1–80 characters with control characters
excluded; supported platforms are `ios`, `android`, `macos`, `linux`, `diagnostic`.
The iPhone stores its installation UUID in its device-local Keychain. Reported names
may be generic or duplicated; this is app identity, not hardware attestation.

`DELETE /v1/client`: authenticated removal of the caller's credential, identity
record and push destination in one transaction. No target client ID is accepted.
Returns `{ "revoked": true }`; an invalid or already removed credential returns 401.
The iPhone treats 401 here as already removed. Network failures and other HTTP
errors preserve the local pairing for retry. Desktop removal uses a local command,
`pacemanctl remove-access --client-id UUID`, and works while sharing is off.

Last successful snapshot/stream delivery is persisted per credential. Private local
status exposes only client ID, reported name/platform, pairing time and contact
time. Neither installation IDs, credential hashes nor secrets enter the panel's
status or remote activity snapshots. Pre-upgrade contact is unknown.

See [pairing and removal](pairing-and-removal.md) for migration and Mac acceptance.

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
In `alert` mode, working and idle updates use passive notification presentation;
needs-input and finished updates use attention alerts. All include a background
refresh request. Passive entries remain visible in the notification list.
`background` mode stays silent and separately throttled. No watch polling is used.
See [direct push delivery](direct-push-test.md) for validation and limitations.

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
BLE theme forwarding is implemented by the alpha profile restoration below.

## Alpha watch profile restoration

The phone now negotiates profile v1–v5 from the watch identity. Rich profiles carry
the source palette and optional Codex allowance; weather is absent pending the
phone provider, brightness remains 50%, and hour cycle remains 24-hour in this
first slice. Profile writes are serialized against activity writes and reconciled
against the last successfully written content. Clock passage alone does not cause
writes on every source poll; reconnect synchronizes time again. Original allowance
observation/reset timestamps are never replaced by transmission time.

Omarchy snapshots may include `allowance` with provider `codex`, remaining (0–100),
window (1 weekly, 2 session), updatedAt and resetsAt (Unix seconds). Missing/invalid
records produce null. This is source-scoped, not verified account identity.
Allowance-only changes advance revision without changing activity eventID or
triggering APNs activity alerts. Profile v4 receives unavailable after staleness or
reset; v5 preserves historical values for the firmware's local expiry rules.
