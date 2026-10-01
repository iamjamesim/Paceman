# APNs relay

The project operates the APNs relay and keeps its signing key off users' Macs. Macs enroll with a source credential; paired iPhones register tokens with a separate credential. The relay accepts only registered source, phone, and token combinations and rejects prompts and transcripts. See [push delivery](push-delivery.md) for notification formats.

## Project operator: deploy on Render

These steps are for the Paceman service operator. A fork can run its own relay with its own signed app and matching Apple Developer credentials; a different team's APNs key cannot send to the public Paceman app.

1. Deploy `Dockerfile.relay` as a paid Web Service. Set its health check to `/healthz`.
2. Create paid Render Postgres in the same region. Set the Web Service's `DATABASE_URL` to its **internal** URL. The relay creates its tables on startup; no manual SQL or `sources.json` is needed.
3. Add Secret Files named `apns-sandbox.p8`, `apns-production.p8`, and `apns.json`. The JSON file must contain both APNs environments, using your Apple team and the corresponding key IDs:

   ```json
   {
     "environments": {
       "development": {
         "teamID": "TEAMID1234", "keyID": "SANDBOX123", "topic": "ai.paceman.app.dev",
         "environment": "development", "keyPath": "/etc/secrets/apns-sandbox.p8"
       },
       "production": {
         "teamID": "TEAMID1234", "keyID": "PRODKEY123", "topic": "ai.paceman.app",
         "environment": "production", "keyPath": "/etc/secrets/apns-production.p8"
       }
     }
   }
   ```

   Debug tokens use the development APNs host; TestFlight tokens use production. A team-scoped key covers the phone and Watch topics in its environment. If the app identifier or team changes, update `teamID`, `keyID`, and `topic`, then re-register the phone token. Keep keys and request bodies out of logs and Git.

## Connect a Mac

After [installing the Mac source](macos.md), point it at the project-operated relay:

```sh
python3 -m macos.install_push --relay-url https://relay.paceman.ai
```

The installer creates a source credential. Pair the iPhone with a fresh QR code, even if it was paired before. The paired iPhone activates the source with Apple's App Attest service; there are no operator-issued invites. Changing relay hosts also requires a fresh pairing.

For an installed Omarchy source, run `python3 -m omarchy.install_push --relay-url https://relay.paceman.ai` from the checkout. Its user push service follows Sharing and uses the same relay for Debug and TestFlight phones. Pair the phone again after configuring or changing the relay address.

## Check and revoke

`/healthz` should list both `development` and `production` under `apnsEnvironments`. After a fresh source event, check `~/Library/Application Support/Paceman/data/push-delivery.jsonl` for APNs `status: 200`, then confirm a **new** update on the physical phone. APNs acceptance alone does not prove display.

Removing phone access also removes its relay destinations. Mac uninstall requests source revocation; if the relay is unreachable, it reports the source ID for manual cleanup. Revoked IDs cannot re-enroll. Postgres stores credential and token hashes, App Attest public keys and counters, and expiring claims. Defaults allow 20 active sources per App Attest key and 500 registrations per day; `PACEMAN_MAX_SOURCES_PER_ATTEST_KEY` and `PACEMAN_DAILY_ENROLLMENT_LIMIT` adjust them. Monitor rejection and rate-limit logs without recording credentials or tokens.

Deploy the iPhone build with App Attest before requiring attestation on the relay. Existing registrations keep working; new Mac pairings need the updated phone. Confirm fresh TestFlight pairing and APNs delivery on a physical iPhone. See [protocol](protocol.md#phone-notifications-and-live-activities) for the wire contract.
