# Push delivery

The optional source worker sends ordinary activity notifications, ActivityKit updates, and optional watchOS allowance updates. For testers, it sends bounded requests to an authenticated relay; only the relay holds the APNs key. Ordinary notifications can reach the experimental ESP32 watch through Apple's Notification Center Service (ANCS). The watch then asks the iPhone to fetch the current authenticated source snapshot and forward it over Bluetooth. The ordinary notification carries a source ID and event hint; ActivityKit receives an expiring display copy. Neither carries a source URL, paired credential, code, prompt, or transcript. See the [wire contract](protocol.md#phone-notifications-and-live-activities).

```text
Source → authenticated relay → APNs → iPhone notification → ANCS → ESP32 watch request
                                         → iPhone fetch → Bluetooth state write
Source → authenticated relay → ActivityKit APNs → iPhone Live Activity
```

| State | Ordinary notification |
| --- | --- |
| Working, Idle | Passive list entry without sound or screen wake. |
| Needs input, Finished | Alert and sound, subject to iOS settings. |

The worker coalesces activity to the newest snapshot, waits at least ten seconds between attempts, discards events over five minutes old, and retries transient failures with backoff. A process crash can duplicate a send. Appearance-only changes do not send activity alerts. The iPhone always fetches from its stored paired endpoint, not a URL supplied by the push.

## Authenticated relay

Each source has a separate random relay credential. The relay stores only its hash in a source allowlist and reloads that list on each request. Removing one source immediately denies its future sends without changing another source or the APNs key. The phone's `POST/GET/DELETE /v1/push`, Live Activity, and watch registrations still belong to its paired source; client removal and re-pairing clear those destinations locally. The worker checks the current client and token before each send. The relay accepts only the three Paceman APNs shapes and an allowlist of fields, constructs the APNs topic itself, and returns bounded status, reason, and APNs ID. It stores no phone tokens or activity history. The relay request carries a phone/watch token, source ID, coarse state and display metadata, or an allowance reading; it carries no prompts, transcripts, source URL, or paired-phone credential. HTTPS is required between source and relay.

See [relay setup](push-relay.md) for source enrollment, revocation, container deployment, and the private config. The worker continues to coalesce and retry from the source database. If a relay is unavailable, the pending event remains eligible until its five-minute activity limit; an explicit client revocation removes the destination immediately. Only one worker can hold a source database's push lock.

## Legacy local APNs provider

The alpha direct sender remains available for existing owner-controlled installs. It uses a private APNs `.p8` key on each configured source and is unsuitable for tester Macs. Its JSON config belongs outside this repository, readable only by its owner. The team, topic, and environment must match the signed iPhone app; Debug uses `development` and Release uses `production`.

```json
{
  "teamID": "TEAMID1234",
  "keyID": "KEYID12345",
  "topic": "com.apselabs.agentcompanion.prototype",
  "environment": "development",
  "keyPath": "AuthKey_KEYID12345.p8"
}
```

These identifiers are examples. `keyPath` can be absolute or relative to the config. The [Mac installer](macos.md#enable-iphone-notifications) installs the sender alongside its paired source. On Omarchy, install `requirements-push.txt` in the provider environment and run `python -m service.push --config CONFIG --data-dir SOURCE_DATA` against the installed paired source database. No public inbound port is needed for the direct setup.

## Delivery boundaries

`apns_accepted` and `live_activity_start_accepted` mean Apple accepted a send. They do not confirm notification presentation, iPhone execution, Bluetooth delivery, or watch rendering. Tailscale reachability, iPhone notification permission, watch notification sharing, Bluetooth proximity, Focus, and system scheduling affect the path. Force-quitting the app is not a supported automatic-wake strategy. Relay hosting and physical-device delivery still need validation. See [known limitations](readiness-gaps.md).
