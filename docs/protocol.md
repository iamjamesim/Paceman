# Source protocol

Each computer is an independent source. Its Mac or Omarchy adapter turns local
agent events into the same snapshot shape; the iPhone pairs with each source,
shows them separately, and chooses fresh activity for the custom watch. This
page describes the v1 rules we intend to keep stable. The current transport is
private Tailscale HTTPS to a service bound to `127.0.0.1`.

## Pairing and access

| Route | What it does |
| --- | --- |
| `POST /v1/pair` | Redeems a five-minute, single-use invitation. Returns `schema`, `sourceID`, `clientID`, `credential`, and `clientManagement: 1`. |
| `GET /v1/snapshot` | Returns the current snapshot with `Authorization: Bearer CREDENTIAL`. Reading it does not acknowledge activity. |
| `DELETE /v1/client` | Revokes the caller's credential and push destinations. The caller cannot name another client. |

A pairing request supplies `invitation` and a `device` with `installationID`
(UUID), `name`, and `platform`. The UUID identifies an app installation; it is
**not** proof of ownership. Re-pairing that
installation requires its current credential and a new invitation, rotates the
credential, and requires push registration again. A matching name alone never
merges installations. The phone keeps each source's credential and cache separate.
See [pairing and removal](pairing-and-removal.md) for recovery and user flows.

## Snapshot

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

| Field | Rule |
| --- | --- |
| `sourceID`, `generation` | Pairing identity and revision-sequence identity, respectively. Both persist for this database; replacing it requires new pairing, but a process restart does not. |
| `state` | One of `idle`, `working`, `needs_input`, `finished`, `failed`. |
| `revision` | Advances when activity or presentation data changes. The phone rejects an older revision within a generation. |
| `eventID`, `changedAt` | Change only for a new activity event; `changedAt` is Unix seconds. An allowance update may raise `revision` without sending another alert. |
| `observedAt`, `freshFor` | Source response time (Unix seconds) and freshness lease (seconds). They show service recency, not proof that an agent is alive. Stale activity cannot outrank fresh activity from another source. |
| `sessions` | Optional agent rows. IDs are opaque; providers and states describe activity without exporting prompts or transcripts. |

Mac uses hook-observed session liveness and clears sessions on restart. Omarchy
verifies owning processes locally. Neither exports process identity; the
adapters own these checks. See [Omarchy recovery limits](omarchy-routing.md).

The phone presents sources independently. Its single custom-watch view chooses
from **fresh** sources in this order: needs input, failed, working, finished,
idle. See [Mac, Omarchy, and APNs payload examples](protocol-examples.md).

## Notifications and watch

`POST /v1/push` registers one alert destination for a paired client; `GET` reports
registration without exposing its token, and `DELETE` removes it. Registration
currently requires `mode: "alert"`.
`POST /v1/live-activity` registers that client's ActivityKit destinations.
These direct APNs routes are private alpha endpoints; a public release needs a
key-safe relay.

An APNs activity alert carries `sourceID`, `generation`, `eventID`, and `revision`
as a **hint**. The phone checks the pairing and fetches its stored source URL;
the push cannot choose a URL or supply credentials or watch state. Presentation
updates do not create activity alerts. See [direct push delivery](direct-push-test.md).

The phone owns the watch aggregate and its monotonic Bluetooth revisions.
Source IDs do not become Bluetooth identities. Watch packet versions are
negotiated separately; an old watch may show a compatible fallback state.
ANCS can request a fresh phone fetch, but the watch has no local source-freshness
lease. See [watch connectivity](../firmware/esp32-watch/docs/connectivity.md).

## Changing v1

- A new adapter can use the same protocol if it maps local events to the five
  states and preserves source identity, ordering, and freshness. New provider
  labels and optional snapshot fields are compatible additions.
- Keep required fields and their meanings stable. A new state, changed event
  identity, or required client behavior needs a new schema or endpoint with
  explicit capability handling. Watch packet versions evolve separately.
- Keep [example payloads](protocol-examples.md) aligned with the implementation
  and tests.
