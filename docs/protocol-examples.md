# Communication examples and watch wire

Illustrative payloads, with invented IDs and times. The Mac and Omarchy objects
are separate `GET /v1/snapshot` responses, not one combined response. The bearer
credential is sent in the HTTP header and never appears here.

## Pairing

The phone redeems a source's single-use invitation with its installation ID:

```json
{
  "invitation": "example-single-use-invitation-token",
  "device": {
    "installationID": "33333333-3333-4333-8333-333333333333",
    "name": "James's iPhone",
    "platform": "ios"
  }
}
```

The source returns a credential for subsequent authenticated requests. This
example credential is invented and is never included in snapshots or pushes.

```json
{
  "schema": 1,
  "sourceID": "11111111-1111-4111-8111-111111111111",
  "clientID": "44444444-4444-4444-8444-444444444444",
  "credential": "example-private-credential"
}
```

## Mac snapshot

An allowance update raised `revision` to 12; activity `eventID` stayed 11.

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
  "sessions": [{"id": "opaque-session-a", "provider": "codex", "state": "needs_input", "workspaceLabel": "paceman"}],
  "allowance": {"provider": "codex", "remaining": 42, "window": 2, "updatedAt": 1790000003, "resetsAt": 1790003600}
}
```

## Omarchy snapshot

This source has its own identity, revision sequence, and freshness lease.

```json
{
  "schema": 1,
  "sourceID": "22222222-2222-4222-8222-222222222222",
  "generation": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "revision": 7,
  "sourceName": "Build Station",
  "observedAt": 1790000004,
  "changedAt": 1790000002,
  "freshFor": 30,
  "state": "working",
  "eventID": "7",
  "sessions": [{"id": "opaque-session-b", "provider": "codex", "state": "working"}]
}
```

## APNs delivery

The ordinary alert refers to Mac activity event 11. A later phone fetch may
receive snapshot revision 12 without treating its allowance update as a new
event. Its APNs push type is `alert`; the `companion` object is a fetch hint, not
the status to display on the custom watch.

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

The separate ActivityKit update carries a display copy of snapshot revision 12.
It goes to the Live Activity's registered token and can render without running
the phone app. Its APNs push type is `liveactivity`. A start push also includes
`attributes` with the source ID and display name.

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

The optional Apple Watch app receives an allowance-only silent push. It does
not carry agent activity to the custom watch:

```json
{
  "aps": {"content-available": 1},
  "schema": 1,
  "allowance": {"provider": "codex", "remaining": 42, "window": 2,
                "updatedAt": 1790000003, "resetsAt": 1790003600}
}
```

## Custom watch packets

BLE uses binary packets, not JSON. This 14-byte activity v1 packet means needs
input, alert and sound requested, phone revision 42, and wearer-acknowledged
revision 39. Multi-byte integers are little-endian.

```text
4f 41 01 02 03 00 2a 00 00 00 27 00 00 00
 O  A  v1 state flags   revision=42   acknowledged=39
```

The watch's eight-byte notification-sync value requests a current fetch; sequence
5 is not a source or watch activity revision:

```text
4f 4e 01 00 05 00 00 00
 O  N  v1    sequence=5
```

All UUIDs share `7f5100xx-1b15-4f0d-b7a5-4cf3a2c98ee1`: service `01`,
profile `02`, identity `03`, activity `04`, notification-sync `05`. Writes use an
authenticated encrypted BLE bond. The watch's 32-byte identity read has `OW`
magic, minimum/maximum profile versions, ownership flag, 16-byte device ID,
32-bit capability flags, and firmware version. Bits 0–5 cover time, clock,
theme, weather, and brightness; bit 6 enables activity, 7 alert sound, 8 distinct
finished, 9 notification-sync, 10 distinct failed, and 11 working sound. The
phone negotiates the profile version and checks capabilities.

The profile packet keeps a common prefix, then appends fields by version:

| Bytes | Profile fields |
| --- | --- |
| `0–35` | `OW`, version, kind `1`, 32-bit revision, Unix time, UTC offset, 12/24-hour choice, flags, 16-byte owner ID. |
| `36–80` (v2+) | Background and foreground RGB, weather observation time, current/high/low temperatures, WMO code, 24-byte location. |
| `81–84` (v3+) | Accent RGB and brightness. |
| `85–102` (v4+) | Allowance remaining (`255` unavailable), window, observation and reset times. |
| `103–110` (v5) | Forecast-day expiry time. |

Integers are little-endian; packet lengths are 36, 81, 85, 103, and 111 bytes
for v1–v5. The 14-byte activity layout is `OA` magic (2), version (1), state
(1), alert/sound flags (1), reserved (1), phone revision (4), and wearer
acknowledgement (4). The eight-byte notification-sync layout is `ON` magic (2),
version (1), reserved (1), and request sequence (4). Published layouts keep
their sizes and meanings; new fields require a negotiated version.

Profile flags mark valid weather (bit 0), Fahrenheit (1), night (2), and a
transient display preview (3). Temperatures are signed whole degrees in the
selected unit. The location is null-terminated UTF-8, capped at 23 data bytes.
