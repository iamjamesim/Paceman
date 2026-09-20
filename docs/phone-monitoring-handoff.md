# Desktop notification delivery handoff

Use the existing trusted Omarchy source and APNs worker. This update adds passive
working/idle notifications to the same delivery path already used for attention
alerts. There is no watch polling, new service, new key, database migration or
experimental command-line flag.

1. Update the checkout to the shared revision and deploy the updated `service/`
   package to the path used by the running worker. The source and worker must use
   the existing source database. Do not start a second source or replace pairing.
2. Restart the existing APNs worker with its existing config and data-directory
   arguments. Inspect its actual executable/working directory; updating the
   checkout alone does not reload an already-running Python process.
3. Verify the installed sender uses Paceman in the notification body. Keep the
   retained private APNs config/key in place; do not print or commit their contents.
4. The phone remains registered in `alert` mode. In the current iPhone UI this is
   **Settings → Developer tools → Push delivery → Notifications**. Older installed
   builds label it **Alert + wake request**. No re-pairing is needed.
5. With the phone locked, trigger Working → Needs input → Working → Finished →
   Idle, holding each state for at least 15 seconds. Observe the watch without
   tapping it or opening the phone. Working/Idle should be passive notification-list
   entries; Needs input/Finished retain their normal alert presentation.
6. Match the source's event identity and `presentation` field to the phone callback,
   fetch and BLE-write records. Repeat after longer idle periods and on cellular.
   A received notification alone does not prove a watch update.

The first visible Finished baseline succeeded with the phone backgrounded for
approximately four minutes. Sustained and passive delivery remain to be verified.
For the initial isolation run, leave foreground streaming and the Live Activity
stopped. Then re-enable the Live Activity and compare both surfaces. The Live
Activity is display-only delivery; it does not itself forward to the BLE watch.

[Delivery policy and validation](direct-push-test.md) ·
[Phone monitoring design](phone-monitoring.md)
