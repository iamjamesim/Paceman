# Desktop release runbook

## Delivery and dependencies

| Platform | Download | Supported systems |
| --- | --- | --- |
| Mac | Self-contained Apple Silicon DMG | macOS 15+; test 15, 26, and 27 |
| Omarchy | Versioned source archive | Omarchy 4.0+, user systemd, Python 3.11+ |

The Mac floor limits the initial compatibility matrix; current APIs can target
older systems. Revisit the floor and Intel support when demand justifies testing.
Both downloads share an annotated `desktop-vVERSION` tag and a
**Desktop VERSION** release. iPhone releases are independent;
check phone/desktop compatibility before either update. Private GitHub releases
require repository access.

Mac updates replace the app using a newer DMG and preserve Application
Support data. Omarchy updates rerun the newer archive. Keep `ai.paceman.macos` and `ai.paceman.source`
stable after the first release.

Mac packages embed the official Sparkle framework pinned in `macos/sparkle.json`.
To enable in-app updates, pass `--updater-config PATH` through release preparation;
that JSON contains only `feedURL` (public HTTPS) and `publicEDKey` (base64 Ed25519
public key). No feed or publisher key is bundled by default: those builds retain
the download-page fallback. `--sparkle-archive PATH` uses the pinned archive offline.

Configured builds check daily and show an Update Available notice without taking
focus. Installation and restart are user-controlled;
unattended installation is disabled. Active work or unresolved responses defer
restart. The handoff stops Paceman's workers, checkpoints SQLite, preserves Sharing
and agent choices, and verifies the new running service build. A failed handoff
keeps recovery data and offers retry; it never automatically restores an older
database. Existing manual installations need one manual updater-enabled upgrade.

Updater publication additionally requires an approved publisher signing key and
feed location. Use Sparkle's official tools to sign the final notarized archive,
appcast and release notes. Signed feeds and pre-extraction verification are required;
signature failure never falls back to unsigned updates. Promote the feed only after
the exact public artifacts pass release QA. Do not replace versioned artifacts.

### Static update feed

The public `iamjamesim/Paceman` repository publishes a separate `gh-pages` branch
from its root, with an empty `.nojekyll` and `CNAME` set to `updates.paceman.ai`.
The root landing page links to desktop downloads in GitHub Releases; Mac feeds
live at `https://updates.paceman.ai/macos/{test,stable}/appcast.xml`. Verify domain
ownership, configure the repository custom domain and DNS, and confirm HTTPS
before building an updater-enabled release. Feed staging requires this exact
custom domain. The marketing site remains separately hosted at `paceman.ai`.

Sparkle's pinned `generate_keys` stores the publisher key in the release Mac's
Keychain under an explicitly chosen account. Establish an encrypted recovery copy
before release; never include the private key in the repository, builds, or feed.
Builds and manifests contain only the feed URL and public key. Existing
Developer ID and notary profiles remain separate credentials.

After the ordinary package QA gate, `publish` can also stage a signed feed locally:

```sh
python3 scripts/desktop_release.py publish "dist/desktop-v$VERSION" \
  --feed-channel test --pages-dir /path/to/separate-gh-pages-checkout \
  --sparkle-archive /path/to/pinned-Sparkle.tar.xz \
  --keychain-account paceman-release --approve-feed-signing
```

The explicit flag authorizes later Keychain use. This command never pushes Pages.
It publishes packages first, rechecks authenticated and anonymous HTTPS downloads,
checks the existing Keychain public key, and uses official `sign_update` to sign
the archive and appcast. Notes are embedded inside the signed appcast. Output is
`macos/test/appcast.xml`; `feed-staging.json` records the URL and local
hashes, not publication.
Signing failure leaves the previous feed intact; retry reuses the public packages.

Use an isolated, updater-enabled baseline to test that feed against the exact
candidate downloads. A stable-configured candidate may be offered on the test
feed; after replacement it returns to its embedded stable URL. Record
`mac-signed-update` and `mac-signed-recovery` against the same package checksums,
then rerun with `--feed-channel stable` to stage `macos/stable/appcast.xml`.
Stable rejects prereleases and requires both signed-trial checks. Test publication
requires the existing package QA checks and a separately approved bounded trial.

Before each separately approved feed push, fetch and fast-forward the dedicated
checkout, rerun staging, review only the intended channel's diff and local evidence,
and commit that feed. Push `gh-pages` without force; packages must already be public.
Wait for the Pages deployment and compare the public HTTPS feed's exact SHA-256
with `feed-staging.json` before reporting success. A failed deployment or mismatch
remains pending; retry the same feed commit rather than replacing release assets.

The Mac bundle includes the runtime pinned in
[`macos/python-runtime.json`](../macos/python-runtime.json) and wheels pinned in
[`requirements-client.txt`](../requirements-client.txt). Users need no separate
Python or package installation. It excludes pip, optional direct-APNs packages,
and hosted relay server dependencies. Review bundled native libraries, licenses,
and security advisories when updating dependencies; hashes alone do not check
for vulnerabilities. Keep exact versions in the lock files and build measurements
in generated release evidence.

## Prepare

Use a clean checkout of the release commit on an Apple Silicon Mac. Confirm its
**Checks** workflow passed. Choose an unused version, increase the build number,
and write customer-facing notes to a local file. Signing requires a Developer ID
Application identity for team `ZTG42P5438` and the `paceman-release` notarization
profile in Keychain.

### With GitHub CLI

Run `gh auth login` once if using CLI release automation:

```sh
VERSION=0.1.0
python3 scripts/desktop_release.py prepare "$VERSION" \
  --build-number 1 --notes-file /tmp/paceman-release-notes.md
```

This checks CI and credentials, creates or verifies the annotated tag, builds both
clients, signs the Mac app and DMG, notarizes, staples, and verifies the packages.
Set `--identity` if there is more than one matching signing identity.

### Without GitHub CLI

Check CI in GitHub's web UI, then create the annotated tag and build locally:

```sh
VERSION=0.1.0
git tag -a "desktop-v$VERSION" -m "Paceman desktop $VERSION"
python3 scripts/prepare-desktop-release.py \
  --version "$VERSION" --build-number 1 --output-dir "dist/desktop-v$VERSION" \
  --identity 'Developer ID Application: Chang Hyun Im (ZTG42P5438)' \
  --notary-profile paceman-release --notes-file /tmp/paceman-release-notes.md
```

This performs the same packaging and Apple verification without GitHub API access.
If the local tag already exists, confirm it points to the chosen commit; do not
recreate or move it.

## Stage and test

**CLI:** run `python3 scripts/desktop_release.py stage "dist/desktop-v$VERSION"`.
It pushes the tag, uploads a draft release, and downloads and verifies the
assets. Test the printed `downloaded-*` directory. Repeating `stage` resumes an
interrupted upload; differing existing assets are rejected.

**Web UI:** push the prepared tag with `git push origin "desktop-v$VERSION"`. In GitHub
**Releases → Draft a new release**, select that existing tag, use **Desktop VERSION**
as the title, paste `RELEASE-NOTES.md` into the description, and attach these three files from
`dist/desktop-v$VERSION/`:

- `Paceman-macos-arm64-VERSION.dmg`
- `Paceman-Omarchy-VERSION.tar.gz`
- `SHA256SUMS`

Keep `release-manifest.json` and `RELEASE-NOTES.md` in the local release directory.
The manifest records build provenance and is used to verify downloaded packages;
the notes supply the release description. Neither is uploaded as an attachment.
`SHA256SUMS` covers only the two packages, so editing the description does not
invalidate package QA.

Save the draft. Download all three files into a new directory, confirm the downloaded
`SHA256SUMS` matches the local original, then run these checks from that directory:

```sh
shasum -a 256 -c SHA256SUMS
xcrun stapler validate "Paceman-macos-arm64-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature \
  "Paceman-macos-arm64-$VERSION.dmg"
```

For either route, test these exact downloads and record results and OS/device
versions beside the release artifacts:

- Upgrade the previous public Mac and Omarchy installations, retaining pairings,
  settings, and unrelated hooks. The first public release has no upgrade baseline.
- Test fresh installations separately, using a clean account or VM. Check the
  supported macOS versions and a real Omarchy installation.
- Follow the [Mac](../macos/README.md) and [Omarchy](../omarchy/README.md) installation
  checks: reviewed hooks, a real Codex event, pairing, APNs acceptance, and a
  notification displayed on a physical iPhone.
- Check login startup, Sharing off/on, restart/reconnection, failed-update recovery,
  and uninstall. Check connected, empty, stale, and multiple-phone menu states.
- Check old/new phone and desktop compatibility and review dependency/license changes.

## Publish

**CLI:** `status` lists pending checks; record each observed result with `qa`:

```sh
python3 scripts/desktop_release.py status "dist/desktop-v$VERSION"
python3 scripts/desktop_release.py qa "dist/desktop-v$VERSION" \
  --check mac-fresh --result passed --notes 'Observed result and OS version'
python3 scripts/desktop_release.py publish "dist/desktop-v$VERSION"
```

Publication requires all checks. Only first-release upgrade checks may be
`not-applicable`. QA is tied to package checksums. `publish` verifies downloads
before and after publication. Versions with `-alpha.N` or `-beta.N` are prereleases;
plain versions such as `0.1.0` are regular releases.

**Web UI:** after completing the same checks, open the saved draft and select
**Publish release**. Select **This is a pre-release** only for alpha/beta versions.
Browser publication does not enforce the script's QA gate;
review the recorded results first. Recheck the published downloads afterward.

Publish the tested files without rebuilding or replacing them. Never move a
public release tag. Do not upload the entire output directory: signing evidence
and local QA records stay local. Generated files under `dist/` are ignored by Git.

## Recovery and local dry runs

If Apple is still processing after five minutes, repeat the packaging command
with `--resume` (do not repeat tag creation). The original DMG and submission ID
are retained in `dist/.desktop-vVERSION.pending/`. If an upload failed before an ID was
saved, inspect Apple history before resubmitting. Rejected builds require a fix
and a new candidate. After a publication network error, recheck the existing
release instead of replacing its assets.

For a local packaging test without Developer ID or notarization:

```sh
python3 scripts/prepare-desktop-release.py \
  --version "$VERSION" --build-number 1 \
  --output-dir "dist/$VERSION-candidate" --adhoc
```

Omarchy archive creation also runs on the Mac release host. Linux CI requires
`systemd-analyze verify` on the unit templates extracted from the archive; Mac CI
checks archive creation without that Linux-only validation. Both jobs verify the
archive checksum.

These `UNSIGNED` candidates are not eligible for distribution. Keep this runbook
updated with changes to the scripts or supported platforms; keep per-release QA
and measurements with that release's evidence.
