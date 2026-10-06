# Push delivery

By default, the source worker sends activity notifications and Live Activity updates through the authenticated relay, which holds the APNs key. It can also push Codex usage to Apple Watch. An ordinary notification reaches the ESP32 watch through Apple's Notification Center Service (ANCS); the watch asks the iPhone to fetch the current snapshot and forward it over Bluetooth. Activity pushes carry an event hint or expiring display copy, never source credentials, prompts, or transcripts. See the [wire contract](protocol.md#phone-notifications-and-live-activities).

| State | Ordinary notification |
| --- | --- |
| Working, Idle | Passive list entry without sound or screen wake. |
| Needs input, Finished | Alert and sound, subject to iOS settings. |

The worker coalesces activity to the newest snapshot, waits at least ten seconds between attempts, discards events over five minutes old, and retries transient failures with backoff. A process crash can duplicate a send. Appearance-only changes do not send activity alerts. The iPhone always fetches from its stored paired endpoint, not a URL supplied by the push.

Apple Watch usage changes are bundled and spaced at least 20 minutes per destination, with periodic recovery sends while readings remain fresh. APNs acceptance does not prove watchOS processed the push.

## Authenticated relay

Deploy relay updates before sources or clients that emit new payload fields. The
relay accepts legacy payloads alongside the current formats.

The phone approves its pairing with App Attest and registers each APNs token hash using its pairing credential before sending the raw token to the Mac. The Mac's first push presents its source credential and locally stored client hash; the relay checks both against the phone's approved token, environment, and mode before calling APNs. Removing a client clears its local destination and queues relay revocation until acknowledged. See [relay setup](../service/RELAY.md) for deployment and revocation, and [protocol](protocol.md#phone-notifications-and-live-activities) for the request contract.

After APNs rejects a Live Activity start token, the source waits 24 hours before retrying that token. A new token or environment can be tried immediately. Re-registering the rejected token does not repair it; ActivityKit controls replacement.

## Development-only direct APNs

The older direct sender remains temporarily for existing personal and Omarchy development setups. It is not a public install path. The phone gets a device **push token** from Apple automatically; the developer-controlled secret here is an APNs **signing key** (`.p8`). [Apple issues a device token for each app](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns) and [associates provider authentication with a developer team and its app topics](https://developer.apple.com/documentation/UserNotifications/establishing-a-token-based-connection-to-apns). Direct sending puts that key on each computer and supports one APNs environment per worker. A developer may use it for a private test build without operating a relay. For a fork distributed outside Paceman's Apple Developer team, use your own relay with your team's key and app signing instead of distributing the key to users' computers. Paceman's relay cannot send to an app signed with another team's app ID.

The JSON config and `.p8` key belong outside this repository; keep the key readable only by its owner (`chmod 600`). The team, topic, and environment must match the signed iPhone app; Debug uses `development` and TestFlight uses `production`.

```json
{
  "teamID": "TEAMID1234",
  "keyID": "KEYID12345",
  "topic": "ai.paceman.app.dev",
  "environment": "development",
  "keyPath": "AuthKey_KEYID12345.p8"
}
```

These identifiers are examples. `keyPath` can be absolute or relative to the config. On Mac, install with `python3 -m macos.install --no-push-setup`, then run `python3 -m macos.install_push --config /absolute/path/to/apns.json`; the key and sender are installed alongside the source.

On Omarchy, install with `bash scripts/install-omarchy.sh --no-push-setup`, then run these commands from the repository root with a private config outside the repository. This is a foreground development worker; stop it when turning Sharing off:

```sh
python3 -m venv "$HOME/.local/state/paceman/direct-push-venv"
"$HOME/.local/state/paceman/direct-push-venv/bin/python3" -m pip install -r requirements-push.txt
cd "$HOME/.local/lib/paceman"
"$HOME/.local/state/paceman/direct-push-venv/bin/python3" -m service.push --config /absolute/path/to/apns.json --data-dir "$HOME/.local/state/paceman"
```

Manage that worker's lifetime separately; the normal Omarchy installer manages only the relay sender. No public inbound port is needed for direct sending.

## Delivery boundaries

`apns_accepted` and `live_activity_start_accepted` mean Apple accepted a send. They do not confirm notification presentation, iPhone execution, Bluetooth delivery, or watch rendering. Tailscale reachability, iPhone notification permission, watch notification sharing, Bluetooth proximity, Focus, and system scheduling affect the path. Force-quitting the app is not a supported automatic-wake strategy.

Live Activity alerts can also appear on a paired Apple Watch. Paceman packages the same four alert sounds in its iPhone and Apple Watch apps, but neither an APNs acceptance nor a simulator build proves that the physical Watch played a sound or haptic. Verify an alerting state change with the iPhone locked and the Watch worn and unlocked; record Watch presentation, sound, and haptic separately.
