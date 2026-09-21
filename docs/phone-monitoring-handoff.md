# Desktop notification delivery handoff

## Notification identity

Visible notifications now use an APNs collapse ID derived from source,
generation and event sequence. Different activity events remain separate entries
in Notification Center; retries of the same event reuse its identity. The
source's `thread-id` groups these entries together. Working/Idle remain passive;
Needs input/Finished retain their existing alert behavior.

Background-only delivery and Live Activities are unchanged. The worker still
coalesces unsent intermediate states and expires old events, so the notification
list is a recent activity trail rather than a complete history.

The change also avoids depending on replacement notifications generating ANCS
modifications for the custom watch. End-to-end watch delivery remains unverified;
the automated tests verify notification identity, retry and grouping behavior.

## Deployment

1. Apply the shared commit to the Omarchy checkout and deploy `service/push.py`
   to the path used by the existing APNs worker. Inspect its executable and
   working directory; updating the checkout alone does not reload the worker.
2. Preserve any local notification-only isolation change to `content-available`
   so this comparison changes only notification identity.
3. Restart the existing worker with its existing config, key and data-directory
   arguments. Keep private files in place. No new service, database migration,
   key, phone registration or firmware installation is needed for this change.
4. The phone should remain registered in **Notifications** mode under
   **Settings → Developer tools → Push delivery**.

## Validation

With the phone locked and Focus off, run two Working → Finished cycles, holding
each state for at least 15 seconds. Keep notification and watch diagnostics
recording throughout; do not tap notifications or open the app during the run.

- Distinct events should appear as separate notifications in the same group.
- Working should remain passive; Finished should retain its alert behavior.
- Each watch update must have a matching ANCS receipt, phone fetch/BLE write and
  firmware-applied state. APNs acceptance or phone presentation alone is not proof
  of watch delivery.
- A retry of the same event must retain the same collapse ID.

Repeat after longer idle periods and with the Live Activity enabled before
claiming reliable delivery. Keep keys, destination tokens and raw device logs out
of the repository.

[Delivery policy and validation](direct-push-test.md) ·
[Phone monitoring design](phone-monitoring.md)
