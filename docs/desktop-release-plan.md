# Desktop release runbook

## Scope and stop rules

One annotated `desktop-vVERSION` tag and **Desktop VERSION** GitHub release hold
an Apple Silicon Mac DMG (macOS 15+) and an Omarchy archive (Omarchy 4+, Python
3.11+, user systemd). iPhone releases are independent. Test macOS 15, 26 and 27
and phone compatibility; record actual coverage, never infer a pass from CI.

Use Python 3.11+ (`python3` below must resolve to that environment) and a clean
checkout of the intended commit with green **Checks**. Choose an
unused final marketing version and a `CFBundleVersion` higher than every prepared
or published build. A fix needs a new version/tag and higher build, including a
fix found during prerelease QA. Old trial evidence does not cover changed source.
Never move tags, rename/replace public assets, rebuild for promotion, or silently
turn an alpha/beta version into stable. Preserve `ai.paceman.macos` and
`ai.paceman.source` identities. Stop on any unexpected settings, hash, signature,
source, asset-identity or QA mismatch. Resolve the cause before retrying.

Agents may prepare code and local evidence. Obtain the user's authorization for
signing, GitHub writes, Pages pushes and installations; do not change account,
repository, DNS or credential settings as part of release preparation. CLI release
commands below need existing `gh` authentication. The web route remains supported;
no CLI login is required when the user performs GitHub writes.

## Build once

Set `VERSION`, `BUILD`, `NOTES`, `UPDATER`, `SPARKLE` and `PAGES` to reviewed local
values. `PAGES` is a separate, fetched/fast-forwarded `gh-pages` checkout of this
repository. Its root has `.nojekyll` and `CNAME` containing `updates.paceman.ai`.
Hosting and HTTPS must already work. Marketing stays at `paceman.ai`.
`UPDATER` contains only the stable public URL and existing publisher **public** key:

```json
{"feedURL":"https://updates.paceman.ai/macos/stable/appcast.xml","publicEDKey":"EXISTING_PUBLIC_ED25519_KEY"}
```

Use the existing Keychain publisher account `paceman-release` and its verified
recovery copy; never export keys into a release directory. Developer ID signing
and notarization use separate credentials. `SPARKLE` is the official archive whose
SHA-256 is pinned in `macos/sparkle.json`. Both feed URLs use the same publisher key.

```sh
python3 scripts/desktop_release.py prepare "$VERSION" --build-number "$BUILD" \
  --notes-file "$NOTES" --updater-config "$UPDATER" --sparkle-archive "$SPARKLE"
RELEASE="dist/desktop-v$VERSION"
python3 scripts/desktop_release.py stage "$RELEASE" --candidate
```

Expected: signed/notarized packages, exact local source/tag, then a draft marked
**prerelease, not latest**; downloaded bytes verified against the local manifest.
`stage --candidate` supports a final numeric version while it is being tested.
Its `candidate.json` binds source/build/notes/checksums and GitHub release/asset
identities. Do not edit it. Repeating stage can resume missing draft uploads;
conflicting existing bytes or changed candidate identities stop it.

For preparation without GitHub CLI, check CI in the web UI, create an unused
annotated tag locally, then run the lower-level packager:

```sh
git tag -a "desktop-v$VERSION" -m "Paceman desktop $VERSION"
python3 scripts/prepare-desktop-release.py --version "$VERSION" \
  --build-number "$BUILD" --output-dir "dist/desktop-v$VERSION" \
  --identity 'Developer ID Application: Chang Hyun Im (ZTG42P5438)' \
  --notary-profile paceman-release --notes-file "$NOTES" \
  --updater-config "$UPDATER" --sparkle-archive "$SPARKLE"
```

With permission, push only that tag and use GitHub **Draft a new release**. Attach
only `Paceman-macos-arm64-VERSION.dmg`, `Paceman-Omarchy-VERSION.tar.gz` and
`SHA256SUMS`. Keep manifest, notes, signing and QA evidence local. Download all
three to a new directory; compare SHA256SUMS with the local original before
checking its package hashes. The unsigned checksum file alone is not a signature.
The web route requires the same checks below; it does not enforce CLI gates.

## Publish a test candidate

First test the downloaded packages: fresh and prior-version upgrades, hooks and
phone delivery, recovery/uninstall, supported macOS versions, Omarchy fresh/upgrade,
and phone compatibility. Follow the installation READMEs. Record each **observed**
result with its OS/device versions; do not bulk-mark tests passed:

```sh
python3 scripts/desktop_release.py status "$RELEASE"
python3 scripts/desktop_release.py qa "$RELEASE" --check mac-fresh \
  --result passed --notes 'Actual result and tested OS version'
python3 scripts/desktop_release.py publish-test "$RELEASE" \
  --pages-dir "$PAGES" --sparkle-archive "$SPARKLE" \
  --keychain-account paceman-release --approve-feed-signing
```

The ordinary eight QA checks must pass (only first-release upgrade checks may be
not applicable). Draft assets are not anonymously downloadable. `publish-test`
therefore publishes the existing draft as **prerelease, not latest**, rechecks
anonymous HTTPS asset hashes, and runs pinned official `generate_appcast` once.
It embeds notes and signs the feed and DMG; public-only CryptoKit verification
checks both signatures against the actual bundled key. A signed one-item feed is
staged locally at `macos/test/appcast.xml`, with evidence and a saved exact copy
beside the packages. Signing failure preserves the previous feed; retry reuses
public assets. A reviewed intent record is saved before feed replacement, so an
interrupted evidence write can recover matching signed bytes without signing again. No Pages push or landing-page generation is automated.

With separate approval, review/commit/push **only** that test feed in `PAGES`.
Wait for deployment, then compare its public HTTPS SHA-256 to
`feed-test-staging.json`. A mismatch is pending, not a successful publication.
The web equivalent is publishing the same assets with **This is a pre-release**
selected and **Set as latest release** off, then using pinned `generate_appcast`
with the existing publisher account and verifying signatures/public bytes as above.
Do not hand-write unsigned XML or promote through the legacy command to bypass QA.

## Test on the user's Mac

An existing updater-enabled, lower-build Paceman can test the candidate. A separate
account is useful for fresh-install isolation but is not a Sparkle requirement.
Get approval before replacing the working app. Preserve a consistent private
backup of `~/Library/Application Support/Paceman` first; never display private keys or pairing secrets.
Confirm the installed bundle's `SUFeedURL`/`SUPublicEDKey` and the candidate's
read-only mounted bundle match the intended stable URL/key and source/build.
The CLI verifier reopens the DMG and checks those embedded values and codesign.

Quit Paceman. Record whether the **per-user** override exists and its exact value
before changing it (use a private local directory for this evidence):

```sh
umask 077
TRIAL=$(mktemp -d "${TMPDIR:-/tmp}/paceman-feed-trial.XXXXXX")
if defaults read ai.paceman.macos SUFeedURL > "$TRIAL/SUFeedURL.before" 2> "$TRIAL/read-error"; then
  defaults read-type ai.paceman.macos SUFeedURL
  touch "$TRIAL/had-override"
fi
```

Proceed only if the existing type is a string, or the error explicitly says the
key/domain does not exist. Stop for other errors; retain `TRIAL` until restoration.
Then, with the app quit:

```sh
defaults write ai.paceman.macos SUFeedURL -string 'https://updates.paceman.ai/macos/test/appcast.xml'
open /Applications/Paceman.app
```

Choose **Check for Updates**, install/restart through Sparkle, and verify the exact
candidate build and running source. This override survives app replacement and
relaunch: embedding stable in the candidate does **not** reset it. Check retained
identity, phone pairings, Sharing/agent choices and history; busy deferral, Skip,
cancel, relaunch and failed-handoff recovery. Follow `macos/README.md` through
user hook review and a fresh saved local task that replies successfully and shows
Finished; verify `lastAgentEventAt` advances. APNs acceptance and physical iPhone
notification display are separate checks. Clean up any diagnostic orphaned activity.

Quit Paceman again and restore the previous override exactly:

```sh
if test -f "$TRIAL/had-override"; then
  defaults write ai.paceman.macos SUFeedURL -string "$(cat "$TRIAL/SUFeedURL.before")"
else
  defaults delete ai.paceman.macos SUFeedURL
fi
open /Applications/Paceman.app
```

Confirm the restored preference (or absence); only an absent override selects the
embedded stable URL. Record `mac-signed-update` and `mac-signed-recovery` using `qa`
as above. The CLI verifies the public test feed and binds each passing result to
its exact signature-bearing bytes and candidate identity. Failed or old QA blocks
promotion. Keep the tested candidate installed; do not downgrade a migrated database.

## Promote the same bytes

```sh
python3 scripts/desktop_release.py promote "$RELEASE" --pages-dir "$PAGES"
```

This requires all ten checks, unchanged source/tag/release/asset identities,
authenticated and anonymous package hashes, the unchanged public test feed and
valid feed/DMG signatures. Newer public builds block an older promotion. It changes
only the existing release's prerelease/latest metadata, rechecks the downloads,
then stages the **exact tested signed feed bytes** at `macos/stable/appcast.xml`.
It does not build, sign again, upload, rename packages, or move tags. Review and
push stable separately **last**; verify its deployed hash. Update the landing
page's links manually with separate approval. Same-byte retries are supported;
a failed check leaves stable unstaged, even if release metadata already changed.

Legacy/manual releases remain supported by `stage` and `publish` without
`--candidate`: hyphenated alpha/beta versions stay prereleases; plain versions
publish normally after QA. That path is not the final-version test/promotion flow.
Updater feed staging still requires explicit signing options. Do not use it to
circumvent a candidate record or reuse QA for rebuilt packages.

## Omarchy: agent-led manual upgrade

No Linux auto-updater is included. With the user's approval, choose the official
release at `github.com/iamjamesim/Paceman/releases`, then download its archive and
`SHA256SUMS` over HTTPS into a fresh directory. Compare the checksum file with the
trusted publisher's release evidence when available; a hash fetched beside an
archive detects corruption, not compromise of that same source.

```sh
BASE="https://github.com/iamjamesim/Paceman/releases/download/desktop-v$VERSION"
curl --disable --fail --location --proto '=https' --proto-redir '=https' \
  --output SHA256SUMS "$BASE/SHA256SUMS"
curl --disable --fail --location --proto '=https' --proto-redir '=https' \
  --output "Paceman-Omarchy-$VERSION.tar.gz" "$BASE/Paceman-Omarchy-$VERSION.tar.gz"
awk -v name="Paceman-Omarchy-$VERSION.tar.gz" '$2 == name {print; n++} END {if (n != 1) exit 1}' \
  SHA256SUMS > SHA256SUMS.omarchy
sha256sum --check --strict SHA256SUMS.omarchy
tar -xzf "Paceman-Omarchy-$VERSION.tar.gz"
cd "Paceman-Omarchy-$VERSION"
pacemanctl status
python3 -c 'from service.compatibility import service_build; print(service_build("."))'
```

Run the download/check commands one at a time; stop on any failure. Require exactly
one matching checksum row and an `OK` result before extraction.
Record the archive version/hash and expected service fingerprint (archives may
report an unknown Git revision). Wait for active work/pending responses to finish.
Preserve a private consistent backup of `~/.local/lib/paceman`, the actual
`${XDG_STATE_HOME:-$HOME/.local/state}/paceman` state, and existing agent hook configs;
stop the source for the snapshot (`pacemanctl stop` also stops its push worker).
Include `~/.codex/hooks.json` and the configured Claude directory’s `settings.json`
when present; keep backup permissions private and record its path.
Do not uninstall, reset pairings or print notification credentials.

```sh
bash scripts/install-omarchy.sh
pacemanctl status
pacemanctl support
systemctl --user status paceman-source.service paceman-push.service --no-pager
```

The installer reloads systemd and restarts enabled Sharing itself, preserving
pairings/history, notification config, agent choices and unrelated hooks. Sharing
previously off must stay off; stopped services then are expected. With Sharing on,
require a fresh running status, matching `serviceBuild.serviceFingerprint` and
support `runningService` observation, retained phones/settings and healthy panel.
Use `pacemanctl logs` for failures; do not repeatedly restart to hide a mismatch.
Follow `omarchy/README.md` for user-reviewed hooks and a fresh successful/Finished
local task. For one supported-request smoke test, use the user's existing supported
native session, ask one harmless input question, have the **user** answer from
iPhone/watch, and verify the task receives it and clears attention. Never answer
or approve on the user's behalf. Verify APNs acceptance and a new physical-phone
notification separately; unavailable native prerequisites remain an explicit QA gap.

## Failures and recovery

Stop publication on a failed trial. Withdraw the bad test-feed commit or replace
it with a previously verified signed feed, with approval; verify deployment. Do
not delete/move public tags or replace published packages. Fix forward with a new
version and higher build. Keep recovery snapshots; do not restore an old database
under new code or run older code against migrated state without an explicitly
verified compatible recovery procedure. Omarchy uses the same forward-fix rule.

Apple processing timeout: rerun the original preparation command with `--resume`;
do not recreate the tag or submit again blindly. After any network error inspect
the existing release/Pages state and retry the same artifacts. A local `--adhoc`
packager run is unsigned, ineligible for publication, and does not test Sparkle
trust or Apple distribution. Keep per-release measurements in local QA/PR evidence.
