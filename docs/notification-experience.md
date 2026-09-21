# Notifications and watch delivery

## User questions, in order

1. Will my watch update while my phone is locked?
2. If not, what exactly must I enable, and where?
3. Which device makes a sound?
4. What changed in my agent work, without opening Paceman?

Bluetooth connection, notification delivery configuration, and actual freshness
are separate facts. Never label configuration as proof of end-to-end delivery.

## Ownership and placement

Settings → Notifications owns permission, delivery registration and the shared
Quiet / Alerts preference. Watch detail keeps Alert sound with the watch controls.
A separate iPhone notifications picker edits the same phone preference. iOS
Notification settings controls sound and presentation. A conditional delivery
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
- No computer: Connect a computer; preserve permission and sound choices.
- Registration pending/failed: distinguish connection/setup from permission.
  Retry registration without asking for permission again.
- Watch disconnected: sharing permission is unknown until connected; never call
  it denied using an old cached value. Reconnect before assessing sharing.
- Watch connected with sharing reported disabled by an authorization-change callback: Settings → Bluetooth → Omarchy Watch → Share
  System Notifications. Use accurate instructions, not an unsupported deep link.
- Configured: show Notifications enabled on the settings page. This is setup
  status, not a guarantee of immediate delivery under Focus or network outages.

Recheck on screen presentation and returning to the foreground. Revocation must
not erase the user's requested notification mode, so re-enabling iOS permission
can recover without another hidden application preference change.

## Phone presentation and watch sound

Quiet sends all states as passive Notification Center entries. Alerts keeps
Working/Idle passive and permits Needs input/Finished to interrupt with requested
sound, subject to iOS settings. Both modes preserve notification entries for ANCS.
The watch's Alert sound remains independent. A paired watch does not automatically
mute an established phone preference. First-time setup through watch pairing
defaults to Quiet. An explicitly saved Quiet / Alerts selection is preserved;
an unset selection defaults to Quiet. The permission request remains standard authorization;
provisional authorization is not enabled pending device validation.

Pairing presents one missing action at a time, without preference controls or
troubleshooting paragraphs. The source acknowledges the presentation preference;
compatibility acknowledgments remain internal. Do not show version or transient
preference-sync notices in the user interface.
Foreground phone presentation also respects Quiet. Live Activity alert routing is
follow-up work and is not implemented by this preference.

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

Watch detail includes a collapsed Not getting updates? section even when setup
looks correct. Check notification permission/Notification Center, watch sharing,
Focus/Scheduled Summary, Bluetooth, and the phone's connection to the computer.
Explain that opening Paceman catches up and is not the intended ongoing workflow;
force-quitting can prevent background operation. Don't recommend repeated pairing.

## Acceptance

Exercise undetermined, denied-before-pairing, denial-in-prompt, authorized,
Notification Center off, sound off, sharing off, disconnected/unknown sharing,
source missing/offline, failed registration, permissions restored, and watch
updates off. Normal configured watch layout stays uncluttered. Review long copy
and accessibility sizing. Automated tests cover state precedence, payload copy,
presentation persistence/registration compatibility and quiet progress. Physical iOS
permission prompts, Settings round trips, sound, and ANCS delivery require device
acceptance. No automatic push/deployment to the desktop.

## Implementation review

Implemented September 21: shared notification recovery, persisted Quiet / Alerts,
contextual watch setup, independent watch sound and phone presentation, and event-based copy.
Simulator review covered permission request, denied, Notification Center disabled
at accessibility sizing, and the normal paired-watch layout. Pairing was reduced
to one next action after review; sound controls remain on the detail page.
53 iOS tests pass. The source suite runs 107 tests with 17 platform-dependent
skips; all 29 focused push/monitoring tests pass. Device build succeeds. The
source update must be deployed before the new payload copy and phone presentation setting
apply. Physical permission round trips, sharing, and sound still need acceptance.
