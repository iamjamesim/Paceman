# APNs relay

The project operates the APNs relay and keeps its signing key off users' computers. A paired iPhone approves a source/client pairing with App Attest and registers hashes of its Apple-issued push tokens. The source keeps the raw tokens. On a send, the relay checks the source credential, paired-client hash, and exact token binding before forwarding bounded activity display data to APNs. It rejects prompts and transcripts. See [push delivery](../docs/push-delivery.md) for notification formats.

## Project operator: deploy on Render

These steps are for the Paceman service operator. A fork can run its own relay with its own signed app and matching Apple Developer credentials; a different team's APNs key cannot send to the public Paceman app.

1. Deploy the repository's [Dockerfile.relay](../Dockerfile.relay) as a paid Web Service. Set its health check to `/healthz`.
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

## Install with the relay

The normal [Mac](../macos/README.md) and [Omarchy](../omarchy/README.md) installers configure `https://relay.paceman.ai` before the first phone pairing. No APNs signing key is installed on the computer. An existing custom notification configuration is preserved on upgrade. To use a self-hosted relay instead, pass `--relay-url https://YOUR-RELAY` to either installer.

If a prior install skipped notification setup or needs repair, run `python3 -m macos.install_push --relay-url https://relay.paceman.ai` on Mac or `python3 -m omarchy.install_push --relay-url https://relay.paceman.ai` on Omarchy from the repository root.

Setup creates a source credential. Pair the iPhone with a fresh QR code if it was paired before relay setup or the relay host changed. The phone approves its pairing with Apple's App Attest service, registers each token hash with the relay, and then gives the raw token to the source. The first authenticated send confirms the source; the Mac worker makes no preliminary registration or client-list sync call.

The Omarchy user push service follows Sharing. Both platforms use the same relay for Debug and TestFlight phones. The phone receives its own APNs device token from Apple; users do not bring a token to installation. A fork signed by a different Apple Developer team needs its own relay and matching APNs key, app IDs, and signing. The project's relay cannot deliver to that fork's app.

## Check and revoke

`/healthz` should list both `development` and `production` under `apnsEnvironments`. After a fresh source event, check `~/Library/Application Support/Paceman/data/push-delivery.jsonl` on Mac or `~/.local/state/paceman/push-delivery.jsonl` on Omarchy for APNs `status: 200`, then confirm a **new** update on the physical phone. APNs acceptance alone does not prove display.

Removing phone access deletes its local destinations and queues an idempotent relay revocation for the old client credential; the worker retries failures. Mac uninstall requests source revocation; if the relay is unreachable, it reports the source ID for manual cleanup. Revoked IDs cannot re-enroll. Postgres stores credential and token hashes, App Attest public keys and counters, pairing approvals, and revocation tombstones. Defaults allow 20 sources per App Attest key and 500 new source approvals per day; `PACEMAN_MAX_SOURCES_PER_ATTEST_KEY` and `PACEMAN_DAILY_ENROLLMENT_LIMIT` adjust them. Monitor rejection and rate-limit logs without recording credentials or tokens.

Deploy the relay and matching iPhone/Mac source builds together for this test. Confirm fresh TestFlight pairing and APNs delivery on a physical iPhone. See [protocol](../docs/protocol.md#phone-notifications-and-live-activities) for the wire contract.
