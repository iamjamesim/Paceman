# Direct APNs delivery and validation

For the trusted alpha, the desktop's existing APNs worker notifies the phone when
agent activity changes. The phone requests the latest snapshot from its paired
HTTPS source and forwards it over the existing Bluetooth connection to the watch.
There is no accessory polling or separate push-test transport.

```text
Desktop source → APNs → phone callback → paired-source fetch → BLE watch
               └─────→ Live Activity display update
```

## Delivery policy

Notification mode is an explicit phone preference that requires notification
permission. Its existing wire value is `alert`; no registration migration is needed.

| Activity | Notification presentation |
| --- | --- |
| Working | Passive; no screen wake or sound, but an entry in the notification list |
| Needs input | Attention alert with default sound, subject to system settings |
| Finished | Attention alert with default sound, subject to system settings |
| Idle | Passive; clears the watch's last activity when the callback succeeds |

Every notification-mode payload includes `content-available: 1` and uses APNs
push type `alert`. Passive entries additionally set `interruption-level: passive`
and omit sound. The foreground app handles passive updates without presenting a
banner, sound or list entry. This does not suppress their background presentation.

Background-only mode remains available without alert permission. It sends no
visible notification and retains the sender's 1201-second minimum between attempts.
Notification mode uses a 10-second minimum. Both modes coalesce pending activity
to the newest event, discard events older than five minutes, and retry transient
failures with backoff. Appearance-only changes do not generate activity alerts.
A process crash can duplicate a send; this is not an exactly-once protocol.

APNs acceptance, notification presentation, app execution and watch rendering are
separate outcomes. A visible notification does not guarantee a background callback.
The callback uses the stored paired endpoint, not a URL from the push. The network
request has a 12-second overall timeout; the handler allows up to three additional
seconds for the BLE write. Tailscale must be connected and the source reachable.
Force-quitting the app is a separate case, not a supported automatic-wake strategy.

## Deployment

Follow [the desktop handoff](phone-monitoring-handoff.md). Update the installed
worker and restart it with its existing config/data-directory arguments. There is
no test flag or alternate service. Updating this Mac checkout does not update the
Omarchy installation or reload its running Python worker.

The retained APNs key belongs to the team signing the phone app. Keep the key and
actual config outside the repository, owner-readable only. Do not commit them,
paste them into chat, or distribute them to testers. Other users of our signed
app need the planned relay; self-builders can use their own developer team.

For a new local setup, the config format is:

```json
{
  "teamID": "TEAMID1234",
  "keyID": "KEYID12345",
  "topic": "com.apselabs.agentcompanion.prototype",
  "environment": "development",
  "keyPath": "AuthKey_KEYID12345.p8"
}
```

These are example identifiers. The key path may be absolute or relative to the
config file; make it private with `chmod 600`. Topic and environment must match
the installed app. Debug uses development; Release uses production. The worker
rejects mismatched environments. APNs signing and the app's remote-notification
background mode must be enabled in its signing profile.

Install `requirements-push.txt` in the existing provider's Python environment.
The worker runs as `python -m service.push --config CONFIG --data-dir SOURCE_DATA`.
Substitute existing private paths. It must point at the actual source database,
not a new synthetic database. Only one worker can hold the database's push lock.
No public inbound port or hosted relay is required for this personal setup.

## Physical validation

1. Verify a foreground source fetch and watch update work. Open **Settings →
   Developer tools → Push delivery**, choose **Notifications** and wait for
   **Registered on desktop**. The old label was **Alert + wake request**. If push
   is off, enable background updates first, then select Notifications.
2. For the initial isolation run, stop the Live Activity and turn **Run stream
   experiment** off. Leave **Forward activity** on. Disconnect the debugger.
3. Lock the phone normally for at least three minutes. On the paired desktop,
   trigger Working → Needs input → Working → Finished → Idle, holding each state
   for at least 15 seconds. Observe the watch before touching either device.
4. Record notification arrival, watch rendering and approximate latency. Passive
   Working/Idle entries do not light the screen or make a sound; inspect the list
   after observing the watch. Do not tap a notification during the unattended run.
5. Repeat several transitions within an hour, then after 30 minutes, two hours,
   and overnight. Check cellular, network recovery and Low Power Mode separately;
   record Focus and notification-summary settings when interpreting timing.
6. Export **Test log → Export timing log** from the phone and correlate it with
   `push-delivery.jsonl` in the source's existing private data directory. Both logs
   remain local. Re-enable the Live Activity afterward to compare both surfaces.

The protocol carries a revisioned current snapshot, not a backlog. A rapidly
superseded transition may be coalesced. The goal is timely current state, with
attention behavior assessed separately. Phone foreground catch-up and wearer-
initiated watch acknowledgement remain normal behavior; neither is periodic watch
polling. Do not touch the watch during isolation runs because an acknowledgement
can also trigger a fetch.

## Evidence and log interpretation

The first visible Finished baseline succeeded after approximately four minutes
with the phone in the background. The callback fetched the matching source event,
and a BLE write was accepted about one second later. The tester observed both the
notification and watch update before interacting. This is one successful event,
not evidence of sustained delivery. Passive Working/Idle delivery remains unverified.

That run used the now-removed polling-capable build with its polling feature off.
No watch-request event occurred during the run. A conservative wait helper reported
unconfirmed while a second same-event write was pending; the second write was
accepted at approximately 3.5 seconds. The polling implementation has since been
removed. Firmware 0.6.1 was rebuilt and flashed with device-side hash verification,
preserving pairing storage, and the cleaned-up iPhone app was installed. Its 50
iOS tests and the 46 push/registration regressions passed. Subsequent validation
uses these ordinary delivery builds.

| Stage | Meaning |
| --- | --- |
| `apns_accepted` / `apns_failed` | Source result from Apple; not device delivery |
| `presentation` | Source classification: active, passive or none |
| `push_background_callback` | App delegate invoked; correlate with app lifecycle to establish background execution |
| `push_notification_opened` | User tapped the notification; not unattended delivery |
| `push_foreground_received` | Notification handled while the app was open |
| `push_fetch_completed` | Latest paired-source snapshot fetched and accepted |
| `ble_write_accepted` | Bluetooth accepted a write for that event; not display confirmation |
| `push_ble_accepted` / `push_ble_unconfirmed` | Handler's bounded wait result |

Payloads contain only source/generation/revision metadata and generic display text,
not task text, code, credentials or endpoint URLs. They are not end-to-end encrypted
notification content. Actual snapshots are fetched through the paired HTTPS source.
The current watch cannot yet expire stale source state locally; inspect the display
during connectivity-loss tests instead of assuming a persistent icon is current.

If branding is stale, check both components. The system supplies the app name from
phone metadata; the desktop supplies the notification body. The earlier Paceman
body correction is in commit `77b2e84`. Check the actual installed worker and restart
its process after deployment, then verify a newly generated notification.

## Fully hidden notifications

Passive notifications remain in the list. Removing a delivered notification is
cleanup, not guaranteed prevention of display. Apple's supported pre-presentation
filtering requires its approved `com.apple.developer.usernotifications.filtering`
entitlement on a Notification Service Extension. This app has neither configured.
An empty notification without that entitlement is not an equivalent mechanism.

The extension runs separately from the app. Entitlement approval alone does not
establish access to its BLE connection or wake the main app. A later prototype
would need to validate supported forwarding and coexistence before depending on
it. Do not add this second process to the current path without that evidence.

## Stop and revoke

**Disable push** deletes the paired destination before unregistering with Apple.
If the source is unreachable, retry rather than silently leaving registration
active. Removing or revoking a source also removes its push destinations. Retain
the existing source database and pairing when restarting the worker.

## References

- [Passive notification presentation](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/passive)
- [Remote notification callbacks](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:didreceiveremotenotification:fetchcompletionhandler:))
- [Background notification limits](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Notification filtering entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering)
- [Filtering entitlement request](https://developer.apple.com/contact/request/notification-service/)
