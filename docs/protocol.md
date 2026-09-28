# Communication protocol

Each Mac or Omarchy computer is an independent source. Its adapter turns local
agent events into a source snapshot. The iPhone pairs with each source, shows
them separately, and sends one selected aggregate to the custom watch. The
source service listens on `127.0.0.1`; the current phone connection uses private
Tailscale HTTPS.

| Path | Payload | Role |
| --- | --- | --- |
| Source → iPhone | Authenticated HTTPS snapshot | Authoritative agent state and freshness. |
| Source → iOS | Ordinary APNs alert | Event hint and, through ANCS, a watch sync request. The phone fetches the snapshot. |
| Source → ActivityKit | APNs start/update/end | A bounded display copy for the Live Activity; it can change without running the app. |
| Source → Apple Watch app | Silent APNs | Optional Codex allowance reading; no custom-watch agent activity. |
| iPhone → custom watch | Encrypted BLE profile and activity packets | Phone-owned settings and one aggregate of fresh source activity. |
| Custom watch → iPhone | BLE notification-sync sequence | Request to fetch current state, not an activity event. |

These are delivery paths for the same source state, with different jobs and wire
formats. ActivityKit renders its own display copy; it does not update the phone's
paired snapshot or the custom watch. See [example payloads](protocol-examples.md).

## Pairing and access

| Route | What it does |
| --- | --- |
| `POST /v1/pair` | Redeems a five-minute, single-use invitation. Returns `schema`, `sourceID`, `clientID`, and `credential`. |
| `GET /v1/snapshot` | Returns the current snapshot with `Authorization: Bearer CREDENTIAL`. Reading it does not acknowledge activity. |
| `DELETE /v1/client` | Revokes the caller's credential and push destinations. The caller cannot name another client. |

A pairing request supplies `invitation` and a `device` with `installationID`
(UUID), `name`, and `platform`. The UUID identifies an app installation; it is
not proof of ownership. Re-pairing that installation requires its current
credential and a new invitation, rotates the credential, and requires push
registration again. A matching name alone never merges installations. The phone
keeps each source's credential and cache separate.

## Source snapshot

A minimal Mac response looks like this (example IDs and times):

```json
{
  "schema": 1,
  "sourceID": "11111111-1111-4111-8111-111111111111",
  "generation": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "revision": 12,
  "sourceName": "Studio Mac",
  "observedAt": 1790000004,
  "changedAt": 1790000000,
  "freshFor": 30,
  "state": "needs_input",
  "eventID": "11",
  "sessions": [{"id": "opaque-session-a", "provider": "codex", "state": "needs_input"}]
}
```

| Field | Meaning |
| --- | --- |
| `schema` | Snapshot format version; currently `1`. |
| `sourceID` | Persistent pairing identity for this source database. Replacing the database requires new pairing. |
| `generation` | UUID identifying this database's revision sequence. A process restart does not change it. |
| `revision` | Advances when activity or presentation data changes. The phone rejects older revisions within a generation. |
| `sourceName` | Source-reported computer name; the phone can use its own display name. |
| `observedAt` | Source response time in Unix seconds, not proof that an agent is alive. |
| `changedAt` | Unix time of the latest activity event; presentation-only updates leave it alone. |
| `freshFor` | Seconds for which the observation can count as current. |
| `state` | `idle`, `working`, `needs_input`, `finished`, or `failed`. |
| `eventID` | Opaque activity identity: 1–128 UTF-8 bytes, no control characters. It stays fixed across presentation-only revisions. |
| `sessions` | Optional agent rows with opaque IDs, provider labels, and states; no prompts or transcripts. |
| `allowance` | Optional Codex usage reading; it can advance `revision` without a new activity event. |

Mac uses hook-observed session liveness and clears sessions on restart. Omarchy
verifies owning processes locally. Neither exports process identity; the
adapters own these checks.

The phone presents sources independently. Its single custom-watch view chooses
from **fresh** sources in this order: needs input, failed, working, finished,
idle. See [Mac and Omarchy examples](protocol-examples.md#mac-snapshot).

## Notifications and Live Activities

Authenticated registration routes are scoped to the paired client:

| Route | Destination |
| --- | --- |
| `POST/GET/DELETE /v1/push` | One ordinary APNs alert destination. Registration sends `deviceToken`, `environment` (`development` or `production`), and optional `displayName`; status never returns the token. |
| `POST /v1/live-activity` | ActivityKit start and update tokens, or their removal. |
| `POST /v1/watch-push` | Optional silent APNs destination for the Apple Watch app's allowance reading; it is not the custom watch activity path. |

The Apple Watch app's direct push is registered with the first paired source.
The phone may also forward a selected allowance by WatchConnectivity; these
readings are source-reported, not a verified cross-machine account total.

An ordinary APNs alert carries `sourceID`, `generation`, `eventID`, and the event's
`revision` as a **hint**. The phone checks its pairing and fetches its stored
source URL. The push cannot choose a URL, supply credentials, or set watch state.
`eventID` is opaque; it need not equal the numeric revision.
ActivityKit APNs instead carries a revisioned, expiring `content-state` for direct
system display. It is a projection of the source snapshot, not a second source
of agent truth. Neither path promises that iOS will run the app or render the
notification. See [the alert and ActivityKit examples](protocol-examples.md#apns-delivery).

The current source worker signs APNs directly with a private team key. That is
a personal alpha setup; public distribution requires a key-safe relay. No phone,
desktop installer, or repository should ship the team's signing key.

## Phone and custom watch

The iPhone owns watch pairing, aggregate selection, and monotonic watch revisions.
Source IDs and source revisions do not become Bluetooth identities or revisions.
The encrypted BLE link uses the established service UUID and these packets:

| Packet | Current format | Purpose |
| --- | --- | --- |
| Identity read | 32 bytes | Watch ID, ownership, supported profile versions, and capability bits. |
| Profile write | v1–v5, 36–111 bytes | Owner, clock, phone-selected palette, weather, preferences, and optional allowance; version is negotiated. |
| Activity read/write/notify | v1, 14 bytes | State, alert/sound flags, phone revision, and wearer-acknowledged revision. |
| Notification-sync read/notify | v1, 8 bytes | `ON`, version, and a watch sequence requesting a current phone fetch. |

Profile versions add fields without changing older layouts: v1 (36 bytes)
contains owner and clock; v2 (81) adds palette and weather; v3 (85) adds accent
and brightness; v4 (103) adds allowance; v5 (111) adds forecast expiry. The
identity read advertises the supported range and capability bits.

Activity state values are `0` idle, `1` working, `2` needs input, `3` finished,
and `4` failed. Finished and failed require their advertised capability bits;
the phone maps them to a supported older state when necessary. Acknowledgement
means the wearer cleared a watch event, not that a source changed state. The
phone sends only fresh aggregate activity and resends current state on reconnect.
The watch packet has **no local source-freshness lease**, so a watch that loses
its phone link cannot expire upstream activity on its own. See the
[packet layouts and examples](protocol-examples.md#custom-watch-packets).

## Evolving the protocol

- A new source adapter can use v1 if it preserves source identity, ordering,
  freshness, and the five state meanings. Provider labels and optional snapshot
  fields can be added without changing required fields.
- A new state, changed event meaning, or required client behavior needs a new
  schema or endpoint with explicit capability handling. APNs display formats and
  BLE packet versions evolve separately from the source snapshot schema.
- Keep [examples](protocol-examples.md), encoders, decoders, and cross-version
  tests together when changing a wire format. Published BLE layouts keep their
  sizes and field meanings; new profile layouts are negotiated.
