# Push delivery

The optional source worker sends ordinary activity notifications, ActivityKit updates, and optional watchOS allowance updates. Distributed installs send bounded requests through the authenticated relay, which holds the APNs key. Ordinary notifications can reach the experimental ESP32 watch through Apple's Notification Center Service (ANCS). The watch then asks the iPhone to fetch the current authenticated source snapshot and forward it over Bluetooth. The ordinary notification carries a source ID and event hint; ActivityKit receives an expiring display copy. Neither carries a source URL, paired credential, code, prompt, or transcript. See the [wire contract](protocol.md#phone-notifications-and-live-activities).

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

The Mac enrolls with a source credential; the phone registers its own token with its pairing credential. The relay checks both identities, the token, environment, and push mode before calling APNs. Removing a client clears its local destination and syncs the removal to the relay. See [relay setup](push-relay.md) for deployment and revocation, and [protocol](protocol.md#phone-notifications-and-live-activities) for the request contract.

The worker retries transient relay failures until the event's five-minute limit. Only one worker can hold a source database's push lock.

## Development-only direct APNs

The older direct sender remains temporarily for existing personal and Omarchy development setups. It is not a public install path: each configured source needs a private APNs `.p8` key. Its JSON config belongs outside this repository, readable only by its owner. The team, topic, and environment must match the signed iPhone app; Debug uses `development` and Release uses `production`.

```json
{
  "teamID": "TEAMID1234",
  "keyID": "KEYID12345",
  "topic": "ai.paceman.app",
  "environment": "development",
  "keyPath": "AuthKey_KEYID12345.p8"
}
```

These identifiers are examples. `keyPath` can be absolute or relative to the config. The [Mac installer](macos.md#enable-iphone-notifications) installs the sender alongside its paired source. On Omarchy, install `requirements-push.txt` in the provider environment and run `python -m service.push --config CONFIG --data-dir SOURCE_DATA` against the installed paired source database. No public inbound port is needed for the direct setup.

## Delivery boundaries

`apns_accepted` and `live_activity_start_accepted` mean Apple accepted a send. They do not confirm notification presentation, iPhone execution, Bluetooth delivery, or watch rendering. Tailscale reachability, iPhone notification permission, watch notification sharing, Bluetooth proximity, Focus, and system scheduling affect the path. Force-quitting the app is not a supported automatic-wake strategy. See [current validation gaps](readiness-gaps.md).
