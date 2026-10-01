# Communication protocol

Each Mac or Omarchy computer is an independent **source**. Its adapter turns
local agent events into a snapshot. The iPhone pairs with sources separately,
displays each one, and selects one fresh aggregate for the ESP32 watch. The
source service listens on `127.0.0.1`; the current phone connection uses
private Tailscale HTTPS.

| Sender → receiver | Wire format | Job |
| --- | --- | --- |
| Source service → Paceman iPhone app | Authenticated HTTPS snapshot | Authoritative agent state and freshness. |
| Source push worker → authenticated relay → iOS Notification Center | Ordinary APNs alert | Notification event and a hint for the phone app to fetch. |
| iOS Notification Center → ESP32 watch | Apple ANCS over BLE | Identifies a Paceman notification so the watch can request a fetch; does not forward APNs JSON. |
| Source push worker → authenticated relay → iPhone Live Activity | ActivityKit APNs | Expiring display copy for the Lock Screen and Dynamic Island. |
| Source push worker → authenticated relay → Paceman watchOS app | Background APNs | Optional Codex allowance reading; the app then reloads its WidgetKit complications. |
| Paceman iPhone app ↔ ESP32 watch | Encrypted BLE packets | Phone-selected profile and activity; watch acknowledgement and fetch requests. |

## Pairing and access

| Route | Purpose |
| --- | --- |
| `POST /v1/pair` | Redeem a five-minute, single-use invitation. |
| `GET /v1/snapshot` | Read current state with `Authorization: Bearer CREDENTIAL`. Reading does not acknowledge activity. |
| `DELETE /v1/client` | Revoke the caller's credential and push destinations. |

The pairing request supplies an installation UUID, a name, and a platform:

```json
{
  "invitation": "example-single-use-token",
  "device": {
    "installationID": "33333333-3333-4333-8333-333333333333",
    "name": "James's iPhone",
    "platform": "ios"
  }
}
```

The source responds with:

```json
{
  "schema": 1,
  "sourceID": "11111111-1111-4111-8111-111111111111",
  "clientID": "44444444-4444-4444-8444-444444444444",
  "credential": "example-private-credential",
  "relayURL": "https://relay.example",
  "relayCredentialHash": "64-lowercase-hex-characters"
}
```

`relayURL` is present when the source uses the hosted APNs relay. When the
source has a relay credential, `relayCredentialHash` is its SHA-256 digest;
the phone uses it to bind App Attest activation to that source before registering
APNs tokens. The source's relay credential is never sent to the phone. The phone
uses its separate paired-client credential to register its own APNs tokens.
The paired-client credential is never
included in snapshots or pushes. An installation ID
is a label, not proof of ownership. Re-pairing the same installation requires
its current credential and a new invitation; it rotates the credential and
requires push registration again. The phone stores each source's access and
cache separately.

## Source snapshot

`GET /v1/snapshot` returns one source, never a combined machine view. For
example, an allowance change raised `revision` to 12 without changing activity
`eventID` 11:

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
  "sessions": [{
    "id": "opaque-session-a",
    "provider": "codex",
    "state": "needs_input",
    "workspaceLabel": "paceman"
  }],
  "allowance": {
    "provider": "codex",
    "remaining": 42,
    "window": 2,
    "windowDurationMins": 300,
    "updatedAt": 1790000003,
    "resetsAt": 1790003600
  }
}
```

| Field | Meaning |
| --- | --- |
| `schema` | Snapshot format version; currently 1. |
| `sourceID` | Persistent UUID for the source database. Replacing the database requires new pairing. |
| `generation` | UUID for that database's revision sequence; a process restart retains it. |
| `revision` | Positive integer advancing for activity or presentation changes. The phone rejects older revisions within a generation. |
| `sourceName` | Source-reported name; the phone may show its own name. |
| `observedAt` | Source response time in Unix seconds, not proof of a live agent. |
| `changedAt` | Latest activity event time; presentation-only changes leave it alone. |
| `freshFor` | Seconds the observation may count as current; the phone accepts greater than 0 and at most 60. |
| `state` | `idle`, `working`, `needs_input`, `finished`, or `failed`. |
| `eventID` | Opaque activity identity, 1–128 UTF-8 bytes without control characters; stable across presentation-only revisions. |
| `sessions` | Optional agent rows with opaque IDs, provider labels, states, and optional bounded workspace labels; no prompts or transcripts. |
| `allowance` | Optional source-reported Codex usage reading; may advance `revision` without a new activity event. |

Omarchy has its own `sourceID`, `generation`, and revisions, using this same
schema. Mac uses hook-observed session liveness and clears sessions on restart;
Omarchy verifies owning processes locally. Neither sends process identity.
The phone presents sources separately. For the ESP32 watch it selects among
**fresh** sources in this order: needs input, failed, working, finished, idle.

## Phone notifications and Live Activities

Push registration is authenticated and scoped to the paired client:

| Route | Destination |
| --- | --- |
| `POST/GET/DELETE /v1/push` | One iPhone ordinary-alert token. Registration sends `deviceToken`, `environment` (`development` or `production`), and optional `displayName`; status omits the token. |
| `POST /v1/live-activity` | iPhone Live Activity start/update token, or its removal. |
| `POST /v1/watch-push` | Optional watchOS app background-push token for allowance only. |

The phone first approves a source/client pairing on the relay. Its five-minute
`POST /v2/attest/challenge` binds the source ID and relay-credential hash,
client ID and pairing-credential hash, App Attest key ID, and APNs environment.
The phone sends the Apple proof to `POST /v2/attest/approve` once for that
pairing. The relay accepts a pending approval without waiting for a Mac call;
it does not finalize ownership of the source ID until a matching Mac send.

For each APNs token, the phone uses its pairing credential to register the
SHA-256 hash of the lowercase token at `PUT /v2/destinations`, then sends the
raw token to the source's local push endpoint. Token updates need no new App
Attest proof. The source stores the raw token and its paired client's credential
hash; the relay stores only hashes. A new token temporarily overlaps the old
binding for ten minutes so a source update cannot be rejected mid-rotation.

The Mac sends bounded activity through `POST /v2/send` with its relay bearer
credential, the locally stored client credential hash, and the raw APNs token.
The relay requires the exact phone-approved source, client, token, environment,
mode, and ActivityKit ID before calling APNs. The first valid send also confirms
the source credential. No separate source registration or whole-client-list sync
is required. Removing or re-pairing a phone deletes its local destination and
queues a durable relay revocation for the old client credential; the phone can
also revoke its own approval. The APNs signing key and topic remain on the
relay. See
[relay setup](../service/RELAY.md).

An ordinary alert (`apns-push-type: alert`) contains user-visible `aps` text
and a small `companion` **fetch hint**. Here the alert refers to activity
event 11; a later fetch can return snapshot revision 12 without treating
the allowance change as a new activity event:

```json
{
  "aps": {
    "alert": {"title": "Codex needs input", "body": "Studio Mac"},
    "thread-id": "11111111-1111-4111-8111-111111111111",
    "sound": "default"
  },
  "companion": {
    "schema": 1,
    "sourceID": "11111111-1111-4111-8111-111111111111",
    "generation": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "eventID": "11",
    "revision": 11
  }
}
```

The iPhone app checks the hint against an existing pairing and fetches its
stored source URL. The push cannot supply a URL or credential or set watch
state. `eventID` need not equal `revision`. iOS decides whether and when to
run the app or display the alert. Working and idle alerts use passive
presentation, but remain `alert` pushes that can appear in Notification
Center and reach the ESP32 watch through ANCS. They are not background pushes.

**ANCS is a different wire format.** The ESP32 watch receives an eight-byte
iOS notification event (`event`, `flags`, `category`, `count`, and a
session-local notification UID). For example, `00 00 00 01 2a 00 00 00`
means an added notification with UID 42; it contains none of the APNs JSON.
The watch asks iOS only for that notification's
`AppIdentifier`. If it matches Paceman, the watch increments its own BLE
notification-sync sequence. The phone then fetches current snapshots and
sends a new activity packet. The watch does not receive the APNs `aps` or
`companion` object, read notification text, or derive agent state from it.
See [Apple's ANCS specification](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html).

ActivityKit receives a separate APNs payload (`apns-push-type: liveactivity`)
with a revisioned, expiring **display copy**. It can update the Live Activity
without running the app, but does not update the phone's paired snapshot or
ESP32 watch. An update for snapshot revision 12 looks like:

```json
{
  "aps": {
    "timestamp": 1790000005,
    "event": "update",
    "content-state": {
      "schema": 1,
      "generation": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "revision": 12,
      "state": "needs_input",
      "working": 0,
      "needsInput": 1,
      "finished": 0,
      "failed": 0,
      "observedAt": 1790000004,
      "freshUntil": 1790000304,
      "changedAt": 1790000000,
      "providers": ["codex"],
      "workspaceLabel": "paceman"
    },
    "stale-date": 1790000304,
    "relevance-score": 179.0000244
  }
}
```

The `content-state` matches the iPhone's `MonitoringActivity.ContentState`:
generation and revision identify the display update; state, counts and
optional provider/workspace labels render it; `freshUntil` and `stale-date`
bound freshness. A start push also carries `attributes` with the source ID
and display name. An end push sets `event` to `end`.

The separate watchOS app may receive an allowance-only background push
(`apns-push-type: background`, `aps.content-available: 1`) at its own app
token from the first paired source. Its notification handler stores the
reading and calls `WidgetCenter.reloadTimelines` for the complications.
WidgetKit's [own push path](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)
uses a different token, `apns-push-type: widgets`, and
`aps.content-changed`. It [starts on watchOS 26](https://developer.apple.com/videos/play/wwdc2025/334/), while Paceman targets
watchOS 11. It requests a timeline reload; the current complication reads
allowance data stored by the watch app, so a reload alone would not supply
a new reading. The phone can also forward a selected reading through
WatchConnectivity. It prefers a recent reading from a connected source in
pairing order; the watchOS background push comes from the first paired source.
Readings from separate Codex accounts are not combined:

```json
{
  "aps": {"content-available": 1},
  "schema": 1,
  "allowance": {
    "provider": "codex",
    "remaining": 42,
    "window": 2,
    "windowDurationMins": 300,
    "updatedAt": 1790000003,
    "resetsAt": 1790003600
  }
}
```

## iPhone and ESP32 watch BLE

The iPhone owns watch pairing, aggregate selection, and watch revisions.
Source IDs and revisions do not become Bluetooth identities or revisions.
The encrypted link uses service
`7f510001-1b15-4f0d-b7a5-4cf3a2c98ee1`:

| Characteristic suffix | Packet | Purpose |
| --- | --- | --- |
| `03` identity | 32-byte `OW` read | Watch ID, ownership, supported profile versions and capabilities. |
| `02` profile | v1–v5 write, 36–111 bytes | Owner, clock, palette, weather, preferences, optional allowance. |
| `04` activity | 14-byte `OA` read/write/notify | State, alert/sound flags, phone revision, wearer acknowledgement. |
| `05` notification sync | 8-byte `ON` read/notify | Watch sequence requesting a current phone fetch. |

For example, the activity packet below means needs input (`2`), alert and
sound requested (`03`), phone revision 42, acknowledgement 39. Integers are
little-endian. The next packet requests a fetch with sequence 5; that number
is neither a source nor an activity revision.

```text
4f 41 01 02 03 00 2a 00 00 00 27 00 00 00   OA v1; state 2; flags 3; revision 42; ack 39
4f 4e 01 00 05 00 00 00                     ON v1; sequence 5
```

The profile layout is negotiated using the identity read:

| Version / length | Fields added to the preceding version |
| --- | --- |
| v1 / 36 bytes | `OW`, version, kind, revision, time, UTC offset, hour cycle, flags, owner ID. |
| v2 / 81 bytes | Palette RGB, weather time and temperatures, WMO code, 24-byte location. |
| v3 / 85 bytes | Accent RGB and brightness. |
| v4 / 103 bytes | Allowance remaining, window, observation and reset times. |
| v5 / 111 bytes | Forecast-day expiry. |

All multibyte values are little-endian. The profile byte ranges are:

| Bytes | Field |
| --- | --- |
| 0–1, 2, 3 | `OW`, version, kind (`1` = profile) |
| 4–7, 8–15, 16–17 | Revision, Unix time, signed UTC offset in minutes |
| 18, 19, 20–35 | Hour cycle (`12` or `24`), flags, 16-byte owner ID |
| 36–38, 39–41 | Background and foreground RGB |
| 42–49, 50–55 | Weather observation time; signed current, high and low temperatures (two bytes each) |
| 56, 57–80 | WMO weather code; null-terminated location |
| 81–83, 84 | Accent RGB; brightness (`20`–`100`) |
| 85, 86, 87–94, 95–102 | Remaining allowance (`255` = unavailable), window (`0` unavailable, `1` weekly, `2` session), observation and reset times |
| 103–110 | Signed forecast-day expiry time |

Profile flags mark valid weather, Fahrenheit, night mode and a transient
preview. The location is null-terminated UTF-8 (at most 23 data bytes).
Capability bits 0–11 respectively advertise time sync, hour cycle, RTC,
theme, weather, brightness, activity, alert sound, distinct Finished,
notification sync, distinct Failed, and Working sound. The identity read also
reports the watch ID, owner status, protocol range and firmware version.
Activity states are 0 idle, 1 working, 2 needs input, 3 finished, 4 failed.
Finished and failed require their capability bits; the phone maps them to
supported older states when needed. Acknowledgement records a wearer action,
not a source change. The phone sends only fresh aggregate activity and resends
current state on reconnect. The watch packet has no local source-freshness
lease, so a watch without its phone link cannot expire upstream activity.

## Evolving the protocol

- New adapters can use snapshot schema 1 if they preserve source identity,
  ordering, freshness and state meanings. Optional metadata can be added.
- New states, changed event meanings or required phone behavior need a new
  schema or endpoint with explicit capability handling. APNs display formats
  and BLE packet versions evolve separately.
- Published BLE layouts keep their sizes and meanings; new profile fields
  require negotiation. Update examples, encoders, decoders and cross-version
  tests together when changing a wire format.

Implementations: [source API](../service/hub.py),
[push encoders](../service/push.py),
[iPhone source decoder](../ios/AgentCompanion/SourceClient.swift),
[iPhone watch link](../ios/AgentCompanion/WatchLink.swift), and
[watch ANCS client](../firmware/esp32-watch/firmware/main/watch_ancs.c).
