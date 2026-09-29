# APNs relay for testers

The relay is a small Python HTTP service in `service/relay.py`. A hosting provider terminates HTTPS; the relay sends to APNs using the server-side `.p8` key. Source workers use only a separate, revocable credential per source. The same `Dockerfile.relay` runs on any container host. The service needs no database, queue, vendor API, or public source endpoint.

## Server secrets

Provide three secret files to the container, outside the image and repository. If the APNs config has a separate `watchKeyID` and `watchKeyPath`, provide its key as a fourth secret file:

| File | Contents |
| --- | --- |
| `/etc/secrets/apns.p8` | Apple APNs private key. |
| `/etc/secrets/apns.json` | APNs identifiers and `keyPath` pointing to `/etc/secrets/apns.p8`. |
| `/etc/secrets/sources.json` | JSON map from source UUID to SHA-256 hash of its relay credential. |
| `/etc/secrets/apns-watch-key.p8` | Separate Watch APNs private key, when configured. Set `watchKeyPath` in `apns.json` to this path. |

The APNs config has the same `teamID`, `keyID`, `topic`, `environment`, and optional separate Watch key fields as the legacy provider. Use a separate relay deployment and config for `development` and `production` tokens. Secret files on a managed host can be mounted read-only; the relay accepts the host's file permissions. The source allowlist is read for every send, so a replacement secret file can revoke a source without restarting the Python process. Some hosts redeploy the container when a secret file changes.

Example `/etc/secrets/apns.json` (identifiers are placeholders):

```json
{"teamID":"TEAMID1234","keyID":"KEYID12345","topic":"com.apselabs.agentcompanion.prototype","environment":"development","keyPath":"/etc/secrets/apns.p8"}
```

Build with `docker build -f Dockerfile.relay -t paceman-relay .`. The image runs `python -m service.relay serve` on the host-supplied `PORT` (default 8080). Set the health check to `GET /healthz`, expose HTTPS publicly at the provider edge, and mount the secret files above. The application itself listens on HTTP inside the container. Keep request-body logging off. Startup validates the APNs key and source allowlist. `POST /v1/send` is authenticated; `/healthz` reveals only readiness of the HTTP process.

## Enroll and revoke a source

Read the source UUID from its owner-only database. For an installed Mac, the database is `~/Library/Application Support/Paceman/data/hub.sqlite3`; for another source, use its configured data directory. For example:

```sh
python3 -c 'import sqlite3; print(sqlite3.connect("SOURCE_DATA/hub.sqlite3").execute("SELECT value FROM metadata WHERE key=?", ("source_id",)).fetchone()[0])'
python3 -m service.relay enroll --sources PRIVATE_SOURCES_JSON SOURCE_UUID
```

The enrollment command prints one random credential once and writes only its hash to the registry file. Transfer that credential privately to the source owner. Put the following JSON in an owner-only file on that source; it must match the source database UUID:

```json
{
  "relayURL": "https://push.example.com",
  "sourceID": "11111111-1111-4111-8111-111111111111",
  "credential": "SOURCE_SPECIFIC_RANDOM_CREDENTIAL"
}
```

Upload the updated `sources.json` as the relay's secret file. To revoke one source, run `python3 -m service.relay revoke --sources PRIVATE_SOURCES_JSON SOURCE_UUID` and upload the updated file. The relay then denies that source's next send. Rotate a source credential by enrolling the same UUID again and replacing both the server allowlist and source config. Do not send a relay credential to the iPhone; it is only for source-to-relay calls. Deleting a phone pairing is separate and immediately removes that phone's push registrations from its source.

On a Mac, run `python3 -m macos.install_push --config OWNER_ONLY_RELAY_JSON` after the source is installed and paired. It copies the relay config into Paceman Application Support and runs the worker in the existing background item. Switching from the legacy direct sender removes Paceman's copied `.p8` files from that installation. On Omarchy, install `requirements-push.txt` and run `python -m service.push --config OWNER_ONLY_RELAY_JSON --data-dir SOURCE_DATA`.

After a fresh activity event, inspect `push-delivery.jsonl` for `apns_accepted` (status 200), then ask the tester to confirm a new alert on the physical iPhone. Apple acceptance and phone display are separate checks. An APNs credential, device token, source URL, prompt, or transcript must not appear in logs.

## Host choice

For a first tester deployment, a small paid Render web service is the least setup: connect the repository, select `Dockerfile.relay`, add three secret files, and set `/healthz`. Its paid 512 MB service avoids the roughly one-minute wake time of its free service. Cloud Run's request-based, scale-to-zero pricing can cost less for sparse traffic, with more initial work for a Google Cloud project, billing, Secret Manager mounts, and image deployment. Both run the same container and expose a normal HTTPS origin; moving later requires changing `relayURL` in source configs (or repointing a domain), uploading the three secrets, and checking APNs acceptance. Use a domain you control if you want to move providers without reconfiguring every source. Current pricing and limits are linked from [Render](https://render.com/pricing), [Render free-service behavior](https://render.com/docs/free), [Cloud Run](https://cloud.google.com/run/pricing), and [Secret Manager](https://cloud.google.com/secret-manager/pricing).
