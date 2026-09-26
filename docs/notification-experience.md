# Notifications and watch delivery

## User questions, in order

1. Will my watch update while my phone is locked?
2. If not, what exactly must I enable, and where?
3. Which device makes a sound?
4. What changed in my agent work, without opening Paceman?

Bluetooth connection, notification delivery configuration, and actual freshness
are separate facts. Never label configuration as proof of end-to-end delivery.

## Ownership and placement

Settings → Notifications owns permission and the recommended
iPhone system configuration. Watch detail keeps Status sounds with the watch controls
and one standard navigation row for watch-update troubleshooting. Global iPhone
notification settings do not remain among the normal per-watch controls. The
troubleshooting screen links to notification setup in context. Desktop registration remains automatic delivery
plumbing and never replaces the phone configuration with a source-availability error.
Paceman classifies progress and attention;
iOS Settings controls Lock Screen, banners, sound and Mac mirroring. Successful
watch pairing confirms the Bluetooth connection, then Continue opens a dedicated
Notifications step. That step owns permission, notification sharing
and the recommended system configuration. A conditional delivery
notice appears under the watch identity only when updates are enabled and setup
needs attention. No success banner remains on the normal watch page. A sampled
false ANCS authorization value is treated as unconfirmed; it must not alone produce a disabled-sharing warning.

After pairing, keep the successful Bluetooth pairing intact and present the next
missing delivery step. Users may finish with limited functionality; do not claim
background delivery is ready just because the watch paired. Existing denied
permission must lead to Settings, never another ineffective permission prompt.

## Ordered recovery states

- Checking: read iOS settings; no premature denied warning.
- Not determined: explain the watch need, then Allow notifications invokes iOS.
- Denied: Notifications are off. Open Settings leads to this app's notification
  settings; returning re-reads settings and synchronizes the existing preference.
- Authorized but Notification Center disabled: enable Notification Center in
  Settings. Banners, Lock Screen placement, and sound are not required.
- Notification mode not selected: Enable notifications, an explicit opt-in.
- Watch disconnected: sharing permission is unknown until connected; never call
  it denied using an old cached value. Reconnect before assessing sharing.
- Watch connected with sharing reported disabled by an authorization-change callback: Settings → Bluetooth → the paired watch → Share
  System Notifications. Use accurate instructions, not an unsupported deep link.
- Configured: show the recommended iPhone notification settings. This is setup
  guidance, not a guarantee of immediate delivery under Focus or network outages.

Recheck on screen presentation and returning to the foreground. Re-enabling iOS
permission must recover without another hidden application preference.
Direct desktop registration retries automatically. Retain its last confirmed receipt,
bound to the source, client, APNs token and environment, so a sleeping computer does
not turn durable setup into a user-facing error. A changed binding invalidates the
receipt and registers again when the source is reachable.

## Phone presentation and watch sound

Working and Idle always use passive presentation: Apple adds them to the
notification list without lighting the screen or playing a sound. Needs input,
Failed, and Finished request active presentation and the default sound when an
accepted Live Activity alert is not carrying that event. Active still obeys
Focus and iOS Settings. The sender never changes this classification based on
a transient accessory connection.

For a watch-first setup, recommend Notification Center on and Lock Screen,
Banners, Sounds and Show on Mac off. This preserves ANCS delivery without cluttering
the phone. Users who want phone alerts can leave their preferred system surfaces
enabled. The watch's Status sounds remain an independent per-watch preference;
its Working cue is sound-only and does not wake or vibrate the watch.
The permission request remains standard authorization; provisional authorization
is not enabled pending device validation.

The Notifications step presents one missing requirement at a time. Once delivery
is ready, it shows the same recommended system configuration as Settings, without
a second Paceman presentation preference. The pairing confirmation does not repeat
notification controls. Pairing and notification-setup actions remain anchored at
the bottom. Both contexts link to iPhone Settings in the guidance; the setup step
also presents it as a quiet secondary button above its primary Done button. Do not
show version or transient sync notices.
When an ActivityKit alert is accepted for Working, Needs input, Failed, or Finished,
the matching Notification Center entry stays passive for custom-watch delivery.
The Live Activity alert uses a short Paceman sound matched to the watch cue.
Idle remains quiet. If ActivityKit cannot accept the alert, the
ordinary Needs input, Failed, or Finished notification retains active presentation
and the default sound; Working remains passive in Notification Center.
APNs acceptance does not prove that the phone played a sound; iOS settings and
Focus still govern presentation.

## Notification content

Titles carry the state: Codex is working / Codex needs input / Codex finished its
turn / No active sessions. Body identifies the computer. Multiple sessions show
state counts, accurately representing the event snapshot. No Open Paceman call to
action, emojis, task-completion claims, or duplicated app name. Use only safe
source/provider/state metadata; no prompts, transcript, arbitrary labels, paths,
or URLs. Task/workspace names are not currently supplied by the event contract.
Read the event payload, not a newer snapshot that could mismatch the event ID.
Retain per-event notification identity and per-source grouping.

## Troubleshooting

Watch detail includes one standard Troubleshoot updates navigation row. Its destination
contains the accessory-specific checks. It links to iPhone notification setup only
when permission or Notification Center actually needs attention. The general
Notifications page does not repeat accessory troubleshooting.
Check notification permission/Notification Center, watch sharing, Focus/Scheduled
Summary, Bluetooth, and the phone's connection to the computer.
Tell users not to swipe Paceman away from the app switcher because force-quitting can
prevent background operation. Don't recommend repeated pairing.

## Acceptance

Exercise undetermined, denied-before-pairing, denial-in-prompt, authorized,
Notification Center off, sound off, sharing off, disconnected/unknown sharing,
source missing/offline, failed registration, permissions restored, and watch
updates off. Normal configured watch layout stays uncluttered. Review long copy
and accessibility sizing. Automated tests cover state precedence, payload copy,
registration compatibility and state-based presentation. Physical iOS
permission prompts, Settings round trips, sound, and ANCS delivery require device
acceptance. No automatic push/deployment to the desktop.

## Implementation review

Implemented September 21: shared notification recovery, a dedicated post-pairing
Notifications step, recommended system settings, independent watch sound, and
event-based copy.
Simulator review covered permission request, denied, Notification Center disabled,
the pairing confirmation and notification setup at standard and accessibility
sizes, and the normal paired-watch layout. Sound controls remain on the detail page.
54 iOS tests pass. All 41 focused push, hub and monitoring tests pass. The full
source suite contains 106 tests with 17 platform skips; two unrelated desktop
installer tests require a normalized non-symlink temporary root on macOS. Device build succeeds. The
source update must be deployed before the state-based presentation policy
applies. Physical permission round trips, sharing, and sound still need acceptance.
