# Phone monitoring and delivery contract

Status: accepted direction, implementation in slices. Phone monitoring does not
require a watch. Progress is passive; attention states request normal iOS alerts.
The multi-computer phone pass retains the existing Live Activity on the primary
computer. Additional computers have independent foreground snapshots and APNs
registrations; a combined Live Activity is a later product decision.

## Surface responsibilities

| Surface | Purpose | Presentation |
| --- | --- | --- |
| App | Inspect current sessions and manage devices | Full detail, authoritative fetch and explicit freshness |
| Live Activity / Dynamic Island | Follow a bounded period of work | One workstation summary initially; needs-input precedes working; brief completion; explicit dismissal |
| Phone alert | Draw attention to meaningful transitions | Needs-input and completion request normal presentation; no progress/reconnect sounds |
| Omarchy Watch | Glance and optional wrist alerts | Existing device-scoped preferences; delivery independent of Live Activities |

A completed turn is not a closed session. Do not keep a Live Activity running
indefinitely because finished sessions remain in a source snapshot. Automatic
start, end and dismissal policy must be validated before normal UI rollout.

## Preference and capability matrix

| Situation | Expected behavior |
| --- | --- |
| Live Activities disabled or dismissed | App, alerts and watch remain independent; do not recreate a dismissed activity repeatedly |
| Notification permission denied | App and Live Activity remain available; explain that custom-watch forwarding requires notifications |
| No watch / disconnected watch | Phone monitoring works; retain newest watch state for catch-up, not alert backlog |
| Watch updates off | Stop that receiver only; phone monitoring continues |
| Everything optional off | Opening the app still fetches current state |
| OS settings change later | Recheck capabilities; keep user intent distinct from current permission; do not nag |
| Source unavailable | Preserve last observation as historical; expire freshness on every surface |
| Phone force-quit / no network | No promise of app execution or accessory forwarding; reconcile on return |

Live Activity existence and Bluetooth connection are not evidence
that a person saw an event. Do not silently suppress opted-in alerts based on them.
One attention event must not cause both a Live Activity alert and an ordinary
phone notification. Foreground haptics and system notification sounds are distinct;
background phone haptics remain controlled by iOS. Respect Focus and silent mode.
Apple Watch system notification routing is not equivalent to a custom BLE receiver.

## Delivery contract

Use the same source ID, generation, monotonically increasing revision, original
observation time, freshness deadline and aggregate counts on all destinations.
Activity identity remains separate from presentation changes (theme/allowance).
No prompts, transcripts, paths or account credentials in APNs display payloads.
A Live Activity needs display state in the push; a fetch-only hint cannot update it.

Destinations are independent: app background token, per-activity update token,
and future push-to-start tokens are not interchangeable.
Pairing credentials authorize registration and removal. Receiver removal/revocation
must remove associated destinations. Token rotation resets destination state.

Track APNs acceptance separately from app fetch and watch acknowledgment. APNs
acceptance is not proof of display or execution. On recovery send newest state;
never replay obsolete attention events. Use expiry and bounded retry/coalescing.
Live Activity freshness is explicit and can expire without an app callback.

A Live Activity update does not imply the app ran or updated the watch.
The callback-only custom-watch route failed a locked-phone run: it fetched only
after a notification tap. Its replacement integrates ANCS: iOS delivers the
notification to the watch, which emits a BLE request for authoritative state.
Core Bluetooth wakes the app to serve that request using the paired source.
There is no accessory polling. Physical acceptance testing is still required. With
notifications enabled, working/idle transitions use passive notifications, while
needs-input and finished request active presentation and sound. Passive entries
remain in the notification list.
This alpha tradeoff does not establish guaranteed app execution or fully hidden
status delivery. The preference matrix above describes product intent; notification-free
continuous custom-watch delivery is not implemented. Notification sharing and
Notification Center delivery are requirements for this path. See
`docs/direct-push-test.md` for setup, limitations and acceptance criteria.
Measure source-to-Live-Activity and source-to-watch latency together on a locked
phone before claiming coherent background delivery.

## APNs ownership

Personal alpha: retain direct APNs from trusted workstations. Reuse the retained
Apple key; the one-download restriction is not one-machine usage. Store it outside
the checkout, owner-readable only, with a local config referring to its path.
Never commit keys, tokens, runtime databases, or actual configuration. The key must
belong to the team signing the installed app and allow its topic/environment.

External testers of our signed app: a small authenticated relay owns Apple's key.
Desktops receive revocable Paceman credentials restricted to their paired receivers,
not APNs signing keys. Support direct mode for self-builders with their own team.
The relay must enforce pairing authorization, destination revocation, payload bounds
and rate limits. It does not remove iOS runtime or push delivery restrictions.

## Implementation and acceptance sequence

Current P0 is iPhone Live Activity/attention notifications, Apple Watch, and the
custom watch. Widgets and complications are deferred. Validate the custom-watch
APNs-to-BLE path before treating the earlier sequence below as complete.

1. Quiet, manually started Live Activity in Developer Tools; independent token
   registration and direct APNs updates. Prove locked-phone updates before product UI.
2. Refine Island/Lock Screen states together: working, needs-input, finished,
   idle, stale, multiple sessions; choose bounded activity lifetime/start/dismissal.
3. Add optional phone attention and one-event/one-alert behavior.
4. Measure watch catch-up alongside each phone surface; revisit system refresh policy.
5. Minimal relay before distributing our signed app to outside users.

Test each surface alone, all together, Live Activities denied, notifications denied,
watch off/disconnected, source restart, token rotation, dismissal, removal,
phone lock/force-quit/relaunch, network loss, duplicate/out-of-order events and expiry.

## Apple references

- [APNs key creation](https://developer.apple.com/help/account/keys/create-a-private-key/)
- [ActivityKit push updates](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- [WidgetKit push updates](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)
- [Background push limits](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

## First slice implementation notes

The manual probe is implemented behind Settings → Developer tools → Live Activity
test. It does not change visible notification preferences or request alert permission.
It registers one activity update token per paired client at `POST /v1/live-activity`,
independently of `/v1/push`. A replacement token/activity supersedes the old one;
conditional removal cannot delete a newer activity. Source revocation removes both.
The existing `service.push` process handles both destinations using the same APNs
configuration; activity pushes use the `.push-type.liveactivity` topic suffix.

The probe uses low-priority quiet updates, coalesces to the latest source revision,
spaces accepted sends by at least 15 seconds, backs off failures, and expires its
registration after one hour. It sends an end event on expiry. The ActivityKit token
observer restores an existing activity on app return; dismissal does not auto-start
another. Offline unregister is best effort, bounded by registration expiry.

This is delivery plumbing and an intentionally small test rendering, not the final
ambient UI or automatic lifecycle policy. No push-to-start or widget push handler
is implemented yet. Activity payloads preserve the source's freshness window, so
an unchanged revision can become stale until the next event. Establishing a useful
bounded freshness lease without excessive pushes is part of the refresh design;
do not misrepresent a stale observation as a confirmed live connection.
