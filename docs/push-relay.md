# APNs relay

The relay is Paceman's production push path. The project operates one relay for the public app; people installing Paceman do not deploy one or receive its APNs key. Macs enroll with a source credential; paired iPhones use a separate credential to register their APNs tokens. The relay sends only to registered source/phone/token combinations. Mac payloads contain status and display metadata; the relay rejects prompt and transcript fields. See [push delivery](push-delivery.md) for the notification formats.

## Project operator: deploy on Render

These steps are for the Paceman service operator. A fork can run its own relay with its own signed app and matching Apple Developer credentials; a different team's APNs key cannot send to the public Paceman app.

1. Deploy `Dockerfile.relay` as a paid Web Service. Set its health check to `/healthz`.
2. Create paid Render Postgres in the same region. Set the Web Service's `DATABASE_URL` to its **internal** URL. The relay creates its tables on startup; no manual SQL or `sources.json` is needed.
3. Add Secret Files named `apns.p8` and `apns.json`. The JSON file must contain the full object below, using your Apple team and key IDs:

   ```json
   {
     "teamID": "TEAMID1234",
     "keyID": "KEYID12345",
     "topic": "com.apselabs.agentcompanion.prototype",
     "environment": "development",
     "keyPath": "/etc/secrets/apns.p8"
   }
   ```

   Use `development` for a debug iPhone build and `production` for TestFlight; the key must allow that environment. If the Watch uses a different key, add an `apns-watch.p8` Secret File and set `watchKeyID` and `watchKeyPath` (`/etc/secrets/apns-watch.p8`) in the JSON. Keep request bodies and keys out of logs and Git.

## Connect a Mac

After [installing the Mac source](macos.md), point it at the project-operated relay:

```sh
python3 -m macos.install_push --relay-url https://YOUR-SERVICE.onrender.com
```

The installer creates a source credential. Pair the iPhone with a fresh QR code, even if it was paired before. Changing relay hosts also requires a fresh pairing.

## Check and revoke

`/healthz` should return `{"ok":true}`. After a fresh source event, check `~/Library/Application Support/Paceman/data/push-delivery.jsonl` for APNs `status: 200`, then confirm a **new** update on the physical phone. APNs acceptance alone does not prove display.

Removing phone access deletes its local destinations and syncs revocation to the relay. Uninstalling a Mac requests source revocation; if the relay is unreachable, the uninstaller reports the source ID for manual cleanup. A revoked ID cannot re-enroll. Postgres stores hashes, never raw credentials or tokens. New source IDs can self-enroll, so monitor abuse before broad invitations. See [readiness gaps](readiness-gaps.md) for current validation and [protocol](protocol.md#phone-notifications-and-live-activities) for the wire contract.
