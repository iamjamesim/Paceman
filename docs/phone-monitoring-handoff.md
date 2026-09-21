# Desktop notification delivery handoff

## Notification setup and presentation preference

The phone exposes Settings → Notifications and watch setup/recovery guidance.
The source stores optional `presentation` per push destination (`quiet` or
`alerts`, default `quiet`) and acknowledges its effective value.
Quiet makes all states passive without sound. Alerts keeps Working/Idle passive
and permits Needs input/Finished to interrupt, subject to iOS settings. Both modes
retain Notification Center entries for ANCS. Deploy the matching source before testing this preference on the phone.

Notification copy uses the event's source name, known provider, and session states.
It does not include prompts, paths, task names, or arbitrary event labels. Finished
means a turn finished. Multi-session titles use counts and the body supplies the
computer and other-state counts without repeating the title.

## Deployment

Update both `service/hub.py` and `service/push.py` through the existing desktop
installation flow and restart the existing source service and APNs worker. The
Store initialization adds a `presentation` column with a Quiet default when absent. Keep the existing database, pairing, APNs key/config and worker arguments.
No new key or re-pairing is needed. Reopening phone notification settings syncs its
saved preference. Nothing is automatically pushed or deployed by this handoff.

Notification payloads omit `content-available`. Background-only delivery and its
developer picker have been removed. This is committed behavior, not a local test override. If a
desktop checkout still has the earlier removal patch, verify that it contains only
this change and replace that patch with the committed implementation before
deploying. Preserve unrelated local changes.

Existing notification registrations remain intact. Legacy background-only
registrations are retired on service startup; those users enable notifications
in the phone app to opt in. Update and restart both source service and worker.

## Acceptance

- Quiet: all states appear as passive entries without phone sound; watch alerts
  remain controlled by the watch preference.
- Alerts: Needs input/Finished request active presentation and sound, subject to
  iOS settings. Working/Idle remain passive.
- Distinct events remain separate entries grouped by source; retries preserve
  event identity. Changing presentation must not skip a pending activity.
- Denied-before-pairing and revoked-after-setup lead to Settings. Returning
  rechecks notification authorization and Notification Center availability.
- Sharing off leads to Settings → Bluetooth → Omarchy Watch instructions;
  disconnected watches do not report sharing as denied from cached state.

Seven successive custom-watch background updates passed the prior distinct-event
run. Unattended reconnect/extended idle and the new presentation/permission round trips
still require physical acceptance. See [bluetooth-lifecycle.md](bluetooth-lifecycle.md).

Keep keys, destination tokens and raw device logs out of the repository.
