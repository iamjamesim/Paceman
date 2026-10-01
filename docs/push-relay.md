# APNs relay

The relay is Paceman's production push path. The project operates one relay for the public app; people installing Paceman do not deploy one or receive its APNs key. Macs enroll with a source credential; paired iPhones use a separate credential to register their APNs tokens. The relay sends only to registered source/phone/token combinations. Mac payloads contain status and display metadata; the relay rejects prompt and transcript fields. See [push delivery](push-delivery.md) for the notification formats.

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

   Debug builds register development tokens; TestFlight builds register production tokens. The relay routes each token to its matching APNs host. Keep the existing Sandbox key if its `.p8` file is available, and create one Production key. A team-scoped key covers the phone and Watch topics in its environment. The existing single-environment JSON remains valid during migration. After changing the app identifier or developer team, update the deployed `teamID`, `keyID`, and `topic` to match the newly signed app, then re-register the phone's push token. Keep request bodies and keys out of logs and Git.

## Connect a Mac

After [installing the Mac source](macos.md), point it at the project-operated relay:

```sh
python3 -m macos.install_push --relay-url https://relay.paceman.ai
```

The installer creates a source credential. Pair the iPhone with a fresh QR code, even if it was paired before. The paired iPhone activates the source with Apple's App Attest service; there are no operator-issued invites. Changing relay hosts also requires a fresh pairing.

The Mac worker syncs a changed pairing list on its next step. When nothing has changed, it reconciles about once per hour, spread across sources to keep idle traffic low. Failed syncs back off; a new pairing bypasses that wait.

For an installed Omarchy source, run `python3 -m omarchy.install_push --relay-url https://relay.paceman.ai` from the checkout. Its user push service follows Sharing and uses the same relay for Debug and TestFlight phones. Pair the phone again after configuring or changing the relay address.

## Check and revoke

`/healthz` should list both `development` and `production` under `apnsEnvironments`. After a fresh source event, check `~/Library/Application Support/Paceman/data/push-delivery.jsonl` for APNs `status: 200`, then confirm a **new** update on the physical phone. APNs acceptance alone does not prove display.

Removing phone access deletes its local destinations and syncs revocation to the relay. Uninstalling a Mac requests source revocation; if the relay is unreachable, the uninstaller reports the source ID for manual cleanup. A revoked ID cannot re-enroll. Postgres stores hashes, never raw credentials or tokens. It also stores attested public keys, assertion counters, and short-lived activation claims. By default, an App Attest key can register up to 20 active sources and the relay accepts up to 500 new source registrations per UTC day. The operator can adjust `PACEMAN_MAX_SOURCES_PER_ATTEST_KEY` and `PACEMAN_DAILY_ENROLLMENT_LIMIT`; the existing 10,000-source total ceiling remains. Relay logs emit `app_attest_activation_accepted`, `app_attest_activation_rejected`, `source_enrollment_accepted`, `source_registration_attestation_required`, `source_registration_limited`, and `push_send_rate_limited` without IDs, credentials, tokens, or request bodies. Set alerts for sustained rejection and rate-limit spikes, and check enrollment counts in Postgres before opening the service broadly.

Release the iPhone build with the App Attest entitlement and verified Apple Developer App IDs first. It recognizes a relay that predates the challenge route and continues the existing registration flow. Then deploy the attestation relay: existing relay registrations retain access, while a newly paired Mac needs the updated iPhone build. Validate a new TestFlight pairing and APNs delivery on a physical iPhone before public release. See [readiness gaps](readiness-gaps.md) for current validation and [protocol](protocol.md#phone-notifications-and-live-activities) for the wire contract.
