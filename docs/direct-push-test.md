# APNs delivery and physical validation

The optional source worker sends activity notifications and ActivityKit pushes. For the custom watch, iOS Notification Center passes Paceman notifications through ANCS; the watch requests a fresh snapshot over the phone's paired Bluetooth and HTTPS links. The push carries no source URL, credential, code, or task text. APNs acceptance, phone presentation, background execution, and watch rendering are distinct outcomes.

| State | Notification |
| --- | --- |
| Working, Idle | Passive list entry, no sound or screen wake. |
| Needs input, Finished | Alert and sound, subject to iOS settings. |

Events are coalesced to the latest snapshot, subject to a ten-second minimum between attempts and a five-minute age limit. Transient failures retry with backoff; a crash can duplicate a send. Tailscale, notification permission, watch notification sharing, Bluetooth proximity, and source reachability all affect delivery. A force-quit app is not a supported automatic-wake path.

## Configure the local provider

Use a private APNs `.p8` key and JSON config outside this repository. The signing team, topic, and environment must match the installed iPhone build; Debug uses `development`, Release uses `production`. Never publish or paste the key. A config shape is:

```json
{
  "teamID": "TEAMID1234",
  "keyID": "KEYID12345",
  "topic": "com.apselabs.agentcompanion.prototype",
  "environment": "development",
  "keyPath": "AuthKey_KEYID12345.p8"
}
```

On Mac, use the [per-user installer](macos.md#enable-iphone-notifications). On Omarchy, install `requirements-push.txt` in the provider environment and run `python -m service.push --config CONFIG --data-dir SOURCE_DATA` against the **installed paired source database**. Only one worker can hold its push lock. This setup does not require a public inbound port. Revoking a source or push destination stops its sends.

## Validate on devices

1. Pair the computer and verify a foreground fetch. Confirm iPhone notifications and Live Activities are enabled as needed. For the custom watch, enable **Watch updates**, allow notification sharing or **Share System Notifications** in Bluetooth settings, and use matching phone and firmware versions.
2. Disconnect the debugger, lock the phone for at least three minutes, and start a new agent session without opening Paceman. Exercise Working → Needs input → Working → Finished → Idle, holding each state long enough to observe. Do not touch the notification or watch during the unattended run.
3. Confirm the Live Activity and notification on the physical phone, and the state on the watch. Repeat with two paired computers; each should retain its own activity. Repeat after a long idle and after Bluetooth disconnection/reconnection.
4. Correlate the phone's **Test log → Export timing log** with the source's `push-delivery.jsonl`. `apns_accepted` and `live_activity_start_accepted` mean Apple accepted the sends, not that the devices displayed them. Look for an ANCS notification event, a paired-source fetch, a BLE write, and visible watch rendering. A foreground open or notification tap does not count as unattended delivery.

An established connection has passed a repeated locked-phone run, but unattended reconnection and longer idle delivery still need physical acceptance. See [Bluetooth lifecycle](bluetooth-lifecycle.md) and [known gaps](readiness-gaps.md).
