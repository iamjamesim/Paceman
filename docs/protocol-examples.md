# Source protocol examples

Illustrative v1 payloads, with invented IDs and times. The Mac and Omarchy
objects are separate `GET /v1/snapshot` responses, not one combined response.
The bearer credential is sent in the HTTP header and never appears here.

## Mac snapshot

An allowance update raised `revision` to 12; activity `eventID` stayed 11.

```json
{
  "schema": 1,
  "sourceID": "11111111-1111-4111-8111-111111111111",
  "generation": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "revision": 12,
  "sourceName": "Studio Mac",
  "mode": "macos",
  "observedAt": 1790000004,
  "changedAt": 1790000000,
  "freshFor": 30,
  "state": "needs_input",
  "eventID": "11",
  "sessionLiveness": "hook",
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
  "mode": "omarchy",
  "observedAt": 1790000004,
  "changedAt": 1790000002,
  "freshFor": 30,
  "state": "working",
  "eventID": "7",
  "sessionLiveness": "process",
  "sessions": [{"id": "opaque-session-b", "provider": "codex", "state": "working"}]
}
```

## APNs hint

This alert refers to Mac activity event 11. A later phone fetch may receive
snapshot revision 12 without treating its allowance update as a new event.

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
