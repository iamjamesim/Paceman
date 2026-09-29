# APNs relay for public testers

The relay is a Python WSGI service in `service/relay.py`, packaged by `Dockerfile.relay`. It holds the APNs signing key. A Mac source has one random relay credential; the iPhone has its separate, source-issued pairing credential. The relay stores hashes of those credentials and hashes of registered APNs tokens in PostgreSQL. It verifies the source, paired client, token, environment, and push mode before every send. A source can only send the bounded Paceman payload shapes in `service/relay.py`; prompts and transcripts are rejected.

**Release gate:** Software tests cover the authorization flow, but this path still needs a staged Render deployment and physical TestFlight device verification. The open source-enrollment endpoint also needs abuse monitoring before broad invitation distribution. Do not call a successful APNs response visible phone delivery.

## Render staging setup

1. Keep the existing paid Web Service in Oregon. Connect the Paceman repository and deploy `Dockerfile.relay` from the reviewed branch. Its Docker command runs Gunicorn. Set the health check to `/healthz`. No custom domain is required for staging.
2. Create a paid Render Postgres instance in the same Oregon region. Set the Web Service's `DATABASE_URL` environment variable to the database's **internal** connection URL. The relay creates its small schema at startup. Do not use a container filesystem, Render disk, or the 30-day free database for its registry.
3. In the Web Service's Secret Files, add `apns.p8` and `apns.json`. The JSON must set `environment` to `production` for TestFlight and `keyPath` to `/etc/secrets/apns.p8`. Verify in Apple Developer that this key is authorized for production APNs; newer keys can be environment-specific. Add a separate Watch key file only if `watchKeyID` differs from the phone key. Do not add `sources.json`; source registration is automatic. Do not print the key in build logs or put it in Git.
4. Deploy and confirm `/healthz` returns `{"ok":true}`. The web service should keep request-body logging disabled. A production TestFlight build uses the `production` APNs environment.
5. Install the Mac source, then run `python3 -m macos.install_push --relay-url https://YOUR-RENDER-SERVICE.onrender.com`. The installer generates and stores a per-source credential in owner-only Paceman Application Support and removes any copied legacy `.p8` key. The worker enrolls the source and syncs the hashed credentials of paired phones. Pair the phone **after** enabling the relay so it receives the relay URL in its pairing response. If already paired, renew that pairing with a fresh QR code.
6. On the physical TestFlight phone, register ordinary notifications, Live Activities, and Watch delivery as applicable. The phone registers each token directly with the relay using its paired-client credential. The Mac also stores the destination locally. Confirm a fresh source event yields APNs acceptance in `push-delivery.jsonl`, then confirm a new notification appears on the phone. Remove phone access and verify a subsequent send is denied. Test a second source to verify isolation.

The relay URL is part of the pairing response and stored with that source on the phone. Moving providers requires updating the source relay URL and renewing pairing; a project domain can avoid that later if useful. Render's [Postgres guide](https://render.com/docs/postgresql-creating-connecting) explains internal URLs and same-region placement. See [pricing](https://render.com/pricing) for current service and database costs.

## Registry and revocation

`POST /v1/sources` creates a source using its 256-bit bearer credential. `PUT /v1/clients` replaces that source's paired-client credential hashes; the worker calls it before sends and on client changes. The phone calls `PUT` or `DELETE /v1/destinations` for its own token bindings. `DELETE /v1/clients/self` removes the phone's relay record. Removing or re-pairing a client on the Mac also removes its relay bindings on the next successful sync. `DELETE /v1/sources` revokes a whole source; send checks require its current credential and a matching destination. The relay permits at most 120 sends per source per minute.

The relay also caps total sends at 3,000 per minute and stores at most 10,000 source IDs, keeping accidental or abusive traffic bounded across self-enrolled sources. These limits can block legitimate testers during an attack; watch the host's request and APNs failure metrics before expanding invitations.

The Mac's existing local direct-APNs sender remains only for owner-controlled development installs. Do not distribute a Mac installation containing the `.p8` key to testers.
