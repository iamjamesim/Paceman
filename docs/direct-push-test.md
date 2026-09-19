# Direct APNs → Tailscale fetch probe

This is a personal transport experiment. There is **no hosted relay** and no new
account system. The APNs signing key stays on the computer running this source.

```
Local synthetic source → Apple APNs → iPhone
                                      │
                          best-effort background callback
                                      │
Local source ← HTTPS over Tailscale ← iPhone → existing BLE watch protocol
```

The `service/` folder is the synthetic test source in **Paceman**. It is
separate from the real desktop bridge in **omarchy-watch**, and from its Codex
hook companion. This change does not install or modify either of those projects.
It also does not implement ANCS in the watch firmware.

## What this experiment can establish

An alert arriving on the lock screen does not prove the app received background
runtime. APNs accepting a request does not prove it reached the phone. A BLE write
being accepted does not prove the watch rendered or sounded the alert.

The app requests background refresh through `content-available` and logs whether
iOS actually calls it. On a callback it fetches the latest snapshot from the
already-paired HTTPS source, then gives the existing BLE write up to three seconds
to complete. The network request has a 12-second overall timeout. Every callback
returns a fetch completion result; this is not an always-running process.

Apple can delay, coalesce, throttle, or omit background delivery. Force-quitting
the app is a separate case and is not a supported automatic-wake strategy.
Tailscale must be connected and able to reach the source during the bounded fetch.

## Prepare the source computer

Run from the Paceman checkout on the **computer that will host the test
source**. For an Omarchy test this means installing the updated test-source files
there; editing this checkout on a Mac does not update the Omarchy machine.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-push.txt
.venv/bin/python -m service.hub serve
```

Keep the existing private Tailscale HTTPS origin pointed at the loopback source
(default port 8765). Use the existing invitation/QR flow to pair the iPhone.
No public inbound port, Tailscale Funnel, or cloud deployment is needed.

## APNs configuration

Use an APNs authentication `.p8` key belonging to the Apple Developer team that
signs this app. Keep it on this computer in a private location; do not commit it,
paste it into chat, or bundle it in an app. A distributed app would need a
different provisioning/relay design; this test uses the developer's own key.

Save `.runtime/apns.json` with these fields (replace the example IDs):

```json
{
  "teamID": "TEAMID1234",
  "keyID": "KEYID12345",
  "topic": "com.apselabs.agentcompanion.prototype",
  "environment": "development",
  "keyPath": "AuthKey_KEYID12345.p8"
}
```

The key path may be absolute or relative to this config file. Make the `.p8`
file readable only by its owner (`chmod 600`). The topic must exactly match the
installed app's bundle ID. Debug uses `development`; Release uses `production`.
The worker refuses to send tokens to the wrong environment. Distribution signing
must use a matching APNs entitlement and provisioning profile.

In Xcode, use the existing signing team and enable **Push Notifications** for the
app's identifier/profile. This capability needs an eligible Apple Developer team;
a free Personal Team is not sufficient for this APNs test. The project includes
the `aps-environment` entitlement and Remote notifications background mode.

Start the provider in a second terminal, in the same checkout and data directory:

```sh
.venv/bin/python -m service.push --config .runtime/apns.json
```

If the hub uses `--data-dir`, pass that same directory to the push worker. Only
one worker can own a database at a time. The worker maintains an HTTP/2 connection
to Apple and caches its ES256 provider token for 50 minutes. It does not require
the source computer to accept incoming internet connections.

## Register the phone and run the test

1. Install this build, pair the source, and verify a foreground fetch works.
2. Tap **Enable push notifications** and allow notifications. Registration sends
   the APNs token over the existing authenticated Tailscale API. The `.p8` key
   never leaves the source computer.
3. Wait for **Registered on desktop · development** (or production). This only
   confirms registration; check the worker's log for APNs acceptance later.
4. Keep **Run stream experiment** off so a surviving SSE connection does not
   disguise the actual wake mechanism. Disconnect the Xcode debugger and USB.
5. Lock the phone. From the source terminal, emit a new event:

   ```sh
   .venv/bin/python -m service.hub emit needs_input
   ```

6. Record whether a lock-screen alert appears and whether the watch changes
   **before touching or unlocking the phone**. Opening the notification is a
   separate test because it gives the app foreground execution.
7. Repeat after 30 minutes, two hours, and overnight; repeat on cellular with
   Tailscale connected. Record Focus/notification settings and Low Power Mode.
8. Return to the app and export its timing log. Compare it with
   `.runtime/push-delivery.jsonl` on the source using the event identity.

For unattended events, the existing scheduler runs without a phone request:

```sh
.venv/bin/python -m service.hub schedule --delay 1800 --interval 1201 --count 5
```

Its sequence is working → needs_input → working → finished → idle. In alert mode
only needs_input and finished send pushes, so the first alert in that example
occurs about 50 minutes after scheduling. Use manual emission for a faster test.

## Two separate modes

- **Alert + wake request** (default): a generic visible alert for needs_input and
  finished, with `content-available: 1`. Minimum 10 seconds between attempts.
  The alert can display even when no background app callback occurs.
- **Silent wake request**: no alert or sound; requests background refresh for any
  new state. The sender allows at most three attempts per hour per unchanged
  registration. Switching modes starts a new experiment and does not replay old
  events. This cannot be used to promise second-by-second status.

Both modes send only the newest eligible event. Events older than five minutes
are discarded and APNs receives a five-minute-or-less expiry. Failed transient
sends retry with backoff; newer states replace obsolete pending work. A process
crash between Apple accepting a request and recording its result can duplicate a
send; the collapse ID and existing watch event IDs limit stale/duplicate state.
The protocol does not claim exactly-once delivery.

## Read the evidence

| Stage | Where | Meaning |
|---|---|---|
| `apns_accepted` | Source log | Apple accepted the request; contains an APNs request ID for investigation |
| `apns_failed` | Source log | Sanitized Apple error or transport failure; no token/key/URL logged |
| `push_background_callback` | Phone log | iOS invoked the app's remote-notification fetch handler |
| `push_notification_opened` | Phone log | User opened an alert; not evidence of unattended execution |
| `push_foreground_received` | Phone log | Notification delegate ran while the app was active |
| `push_fetch_completed` | Phone log | Latest paired-source snapshot was fetched and accepted |
| `push_ble_accepted` | Phone log | That event had a confirmed BLE write; not proof of rendering |
| `push_ble_unconfirmed` | Phone log | No confirmed write within the short window, or no ready watch |

Pushes contain no source URL, source credential, task text, or code. The source ID
and revision are routing/diagnostic metadata. The generic alert text is visible to
Apple; this is not an end-to-end encrypted notification payload. Actual snapshot
data is fetched through Tailscale.

The current watch firmware still cannot expire stale source state locally. Inspect
the watch during connectivity-loss tests; a persistent old indicator is a known
limitation. ANCS is a distinct next experiment if app wake-and-fetch is unreliable.

## Stop and revoke

**Disable push** deletes this paired phone's destination before unregistering with
Apple. It reports a failure if the source is unreachable so the destination is
not silently left active. Removing a source also disables its push registration.
From the source, `service.hub clients` lists paired client IDs and
`service.hub revoke CLIENT_ID` revokes reads and removes that client's push token.
Stop the provider with Ctrl-C and cancel scheduled events with
`service.hub cancel-schedule` when finished.

## Validation

See `validation.md` for the actual build/test evidence and outstanding
hardware checks. A simulator test or mocked APNs response cannot validate locked
iPhone background behavior.

Apple references:
- [Background notification limits](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Registering with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Provider requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)

## 2026-09-18 product behavior correction

Normal iPhone activity delivery now registers for silent background pushes without
requesting alert authorization. Existing prototype alert-mode preferences migrate
once to background mode. Pairing enables background registration automatically;
foreground fetch recovery retries an unsuccessful desktop registration, at most
once per 30 seconds. Visible alerts remain an explicit developer-tool test only.
The desktop must be reachable for the stored destination to change modes; pending
APNs messages are not recalled by changing the local preference.

The home screen no longer presents notification permission or registration as a
setup requirement. Foreground activity polling retries after each request with a
five-second delay (unless access was revoked), so connection recovery has a stable
label rather than a Retry button that dims during each request. Background iOS
execution is discretionary: this change does not establish continuous background
watch updates. The existing background sender cap remains one attempt per 1201
seconds, and physical background delivery acceptance still needs verification.
