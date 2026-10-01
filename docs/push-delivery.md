# Push delivery

The source worker sends activity notifications and Live Activity updates through the authenticated relay, which holds the APNs key. It can also push Codex allowance to Apple Watch. An ordinary notification reaches the ESP32 watch through Apple's Notification Center Service (ANCS); the watch asks the iPhone to fetch the current snapshot and forward it over Bluetooth. Activity pushes carry an event hint or expiring display copy, never source credentials, prompts, or transcripts. See the [wire contract](protocol.md#phone-notifications-and-live-activities).

| State | Ordinary notification |
| --- | --- |
| Working, Idle | Passive list entry without sound or screen wake. |
| Needs input, Finished | Alert and sound, subject to iOS settings. |

The worker coalesces activity to the newest snapshot, waits at least ten seconds between attempts, discards events over five minutes old, and retries transient failures with backoff. A process crash can duplicate a send. Appearance-only changes do not send activity alerts. The iPhone always fetches from its stored paired endpoint, not a URL supplied by the push.

Apple Watch allowance changes are spaced at least 20 minutes per destination, with periodic recovery sends while the reading remains fresh. APNs acceptance does not prove watchOS processed the push.

## Authenticated relay

The Mac enrolls with a source credential; the phone registers its own token with its pairing credential. The relay checks both identities, the token, environment, and push mode before calling APNs. Removing a client clears its local destination and syncs the removal to the relay. See [relay setup](push-relay.md) for deployment and revocation, and [protocol](protocol.md#phone-notifications-and-live-activities) for the request contract.

After APNs rejects a Live Activity start token, the source waits 24 hours before retrying that token. A new token or environment can be tried immediately. Re-registering the rejected token does not repair it; ActivityKit controls replacement.

## Development-only direct APNs

The older direct sender remains temporarily for existing personal and Omarchy development setups. It is not a public install path: each configured source needs a private APNs `.p8` key. Its JSON config belongs outside this repository, readable only by its owner. The team, topic, and environment must match the signed iPhone app; Debug uses `development` and Release uses `production`.

```json
{
  "teamID": "TEAMID1234",
  "keyID": "KEYID12345",
  "topic": "ai.paceman.app.dev",
  "environment": "development",
  "keyPath": "AuthKey_KEYID12345.p8"
}
```

These identifiers are examples. `keyPath` can be absolute or relative to the config. The [Mac installer](macos.md#enable-iphone-notifications) installs the sender alongside its paired source. On Omarchy, install `requirements-push.txt` in the provider environment and run `python -m service.push --config CONFIG --data-dir SOURCE_DATA` against the installed paired source database. No public inbound port is needed for the direct setup.

## Delivery boundaries

`apns_accepted` and `live_activity_start_accepted` mean Apple accepted a send. They do not confirm notification presentation, iPhone execution, Bluetooth delivery, or watch rendering. Tailscale reachability, iPhone notification permission, watch notification sharing, Bluetooth proximity, Focus, and system scheduling affect the path. Force-quitting the app is not a supported automatic-wake strategy.

Live Activity alerts can also appear on a paired Apple Watch. Paceman packages the same four alert sounds in its iPhone and Apple Watch apps, but neither an APNs acceptance nor a simulator build proves that the physical Watch played a sound or haptic. Verify an alerting state change with the iPhone locked and the Watch worn and unlocked; record Watch presentation, sound, and haptic separately.
