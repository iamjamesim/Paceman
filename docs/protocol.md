# Prototype contract v1

All remote paths require TLS from Tailscale Serve. The Python listener binds
only to 127.0.0.1. This is a private development service, not an internet-facing
production server. Limit tailnet access to the devices participating in the test.

`POST /v1/pair`: JSON `{ "invitation": "single-use secret", "device": {
"installationID": "UUID", "name": "Alex’s iPhone", "platform": "ios" } }`.
Returns schema, sourceID, clientID, credential, and `clientManagement: 1`.
Invalid/expired/used invitations return 401; invalid bodies 400; excessive attempts
429. Invitation expiry is five minutes. `device` is required. Pre-identity
development pairings are outside this contract; start those tests with fresh
source data and a new pairing code.

Installation IDs are claims, not credentials. To re-pair an existing installation,
include its current `Authorization: Bearer CREDENTIAL` and a fresh invitation.
The source rotates the credential in place, keeps the client ID and pairing date,
clears its old push registration and contact time.
The phone must register push again. A claimed installation already owned by a
different credential returns 409 without consuming the invitation. Matching device
names never cause a merge. A revoked installation can pair afresh with a new code.

Names are plain text, 1–80 characters with control characters
excluded; supported platforms are `ios`, `android`, `macos`, `linux`, `diagnostic`.
The iPhone stores its installation UUID in its device-local Keychain. Reported names
may be generic or duplicated; this is app identity, not hardware attestation.

`DELETE /v1/client`: authenticated removal of the caller's credential, identity
record and push destination in one transaction. No target client ID is accepted.
Returns `{ "revoked": true }`; an invalid or already removed credential returns 401.
The iPhone treats 401 here as already removed. Network failures and other HTTP
errors preserve the local pairing for retry. Desktop removal uses a local command,
`pacemanctl remove-access --client-id UUID`, and works while sharing is off.

Last successful snapshot delivery is persisted per credential. Private local
status exposes only client ID, reported name/platform, pairing time and contact
time. Neither installation IDs, credential hashes nor secrets enter the panel's
status or remote activity snapshots.

See [pairing and removal](pairing-and-removal.md) for physical acceptance.

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

`mode` is `synthetic`, `omarchy`, or `macos`. Live desktop snapshots use the same API and
pairing contract. `revision` advances for activity or appearance changes; `eventID`
and `changedAt` advance only for activity changes. They need not equal the latest
snapshot revision. Appearance updates therefore cannot replay a watch alert.
The source's `observedAt` establishes service liveness. Omarchy sources with
`sessionLiveness: "process"` additionally verify each listed session's owning
Codex process locally. Finished and Idle sessions can remain open. PID/start-time/
boot metadata is never exported. Clients can ignore this optional marker.
See [routing semantics and recovery limits](omarchy-routing.md).
Mac snapshots use `sessionLiveness: "hook"`; their sessions are observed hook
states and are cleared on source restart because open-process identity is not
verified. The phone must keep each source's generation, revision, freshness,
credential and cache separate.

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

Firmware 0.6.2 adds notification synchronization capability bit 9 and an encrypted
read/notify characteristic `7f510005-1b15-4f0d-b7a5-4cf3a2c98ee1`. Its eight bytes
are `ON`, version 1, reserved zero, then a little-endian uint32 request sequence.
The sequence increases when ANCS identifies a new/modified Paceman notification.
It is a request for current source state, not an activity revision or a wearer
acknowledgement. It resets on watch reboot; every new BLE handshake performs a
current-state fetch regardless. Receivers coalesce duplicate sequences and queue
one follow-up if a new request arrives during an existing fetch. Old firmware
continues using the unchanged activity/profile formats.

The ANCS client subscribes to iOS Service Changed, Data Source, and Notification
Source on the existing encrypted connection. It requests AppIdentifier only,
ignores notification removal and initial Added+PreExisting replay (but retains
Modified events), and never parses human
notification content as a data protocol. A bounded queue coalesces overflow into
a current-state request. No periodic request or keepalive is emitted.
# Direct push destination extension

The optional direct-APNs probe adds `/v1/push` to this test source. All three
methods require the same paired `Authorization: Bearer …` credential as snapshot
reads. The server derives ownership from that credential; callers cannot select
another client ID. These are private Tailscale endpoints, not a public relay API.

- `POST`: `{ "deviceToken": "lowercase hex", "environment": "development" | "production", "mode": "alert" }`.
  Validated payloads upsert that client's destination. Re-registering an unchanged
  token preserves pending work and retry state. A changed token or environment starts
  after the current event, avoiding historical alert replay.
  The wire field `mode` remains fixed at `alert`; background-only registrations are rejected.
- `GET`: returns `registered`, and when present `environment`, `mode`,
  `lastResult`, `lastAPNsID`. POST returns the same registration status. Neither response returns a destination token.
- `DELETE`: removes only this client's push destination. Revoking the client also
  removes its destination. Requests with invalid/revoked credentials return 401.

The direct sender adds a `companion` hint alongside `aps`, with `schema: 1`,
`sourceID`, `generation`, `eventID`, and integer `revision`. The phone validates
the hint against its pairing, then fetches `/v1/snapshot` from its stored source.
The push does not control the fetch URL, credentials, or resulting watch state.
In `alert` mode, working and idle updates use passive notification presentation;
needs-input and finished request active presentation and sound. These are alert-type pushes and omit
`content-available`; ANCS, rather than a background callback, initiates custom-watch
synchronization. Passive entries remain visible in the notification list. The
retired `background` mode is rejected. No watch polling is used.
See [direct push delivery](direct-push-test.md) for validation and limitations.

## Optional phone snapshot metadata

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
