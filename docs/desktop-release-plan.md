# Desktop release runbook

## Delivery and dependencies

| Platform | Download | Supported systems |
| --- | --- | --- |
| Mac | Self-contained Apple Silicon DMG | macOS 15+; test 15, 26, and 27 |
| Omarchy | Versioned source archive | Omarchy 4.0+, user systemd, Python 3.11+ |

The Mac floor limits the initial compatibility matrix; current APIs can target
older systems. Revisit the floor and Intel support when demand justifies testing.
Both downloads share one annotated desktop tag. iPhone releases are independent;
check phone/desktop compatibility before either update. Private GitHub releases
require repository access.

Mac alpha updates replace the app using a newer DMG and preserve Application
Support data. Omarchy updates rerun the newer archive. Add signed Sparkle updates
before broad stable distribution. Keep `ai.paceman.macos` and `ai.paceman.source`
stable after the first release.

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
VERSION=0.1.0-alpha.1
python3 scripts/desktop_release.py prepare "$VERSION" \
  --build-number 1 --notes-file /tmp/paceman-release-notes.md
```

This checks CI and credentials, creates or verifies the annotated tag, builds both
clients, signs the Mac app and DMG, notarizes, staples, and verifies the packages.
Set `--identity` if there is more than one matching signing identity.

### Without GitHub CLI

Check CI in GitHub's web UI, then create the annotated tag and build locally:

```sh
VERSION=0.1.0-alpha.1
git tag -a "v$VERSION" -m "Paceman desktop $VERSION"
python3 scripts/prepare-desktop-release.py \
  --version "$VERSION" --build-number 1 --output-dir "dist/v$VERSION" \
  --identity 'Developer ID Application: Chang Hyun Im (ZTG42P5438)' \
  --notary-profile paceman-release --notes-file /tmp/paceman-release-notes.md
```

This performs the same packaging and Apple verification without GitHub API access.
If the local tag already exists, confirm it points to the chosen commit; do not
recreate or move it.

## Stage and test

**CLI:** run `python3 scripts/desktop_release.py stage "dist/v$VERSION"`.
It pushes the tag, uploads a draft prerelease, and downloads and verifies the
assets. Test the printed `downloaded-*` directory. Repeating `stage` resumes an
interrupted upload; differing existing assets are rejected.

**Web UI:** push the prepared tag with `git push origin "v$VERSION"`. In GitHub
**Releases → Draft a new release**, select that existing tag, paste the generated
release notes, mark it as a prerelease, and attach these five files from
`dist/v$VERSION/`:

- `Paceman-macos-arm64-VERSION.dmg`
- `Paceman-Omarchy-VERSION.tar.gz`
- `SHA256SUMS`
- `release-manifest.json`
- `RELEASE-NOTES.md`

Save the draft. Download all five files into a new directory, confirm the downloaded
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
python3 scripts/desktop_release.py status "dist/v$VERSION"
python3 scripts/desktop_release.py qa "dist/v$VERSION" \
  --check mac-fresh --result passed --notes 'Observed result and OS version'
python3 scripts/desktop_release.py publish "dist/v$VERSION"
```

Publication requires all checks. Only first-release upgrade checks may be
`not-applicable`. QA is tied to package checksums. `publish` verifies downloads
before and after publication and keeps the release marked as a prerelease.

**Web UI:** after completing the same checks, open the saved draft and select
**Publish release**. Browser publication does not enforce the script's QA gate;
review the recorded results first. Recheck the published downloads afterward.

Publish the tested files without rebuilding or replacing them. Never move a
public release tag. Do not upload the entire output directory: signing evidence
and local QA records stay local. Generated files under `dist/` are ignored by Git.

## Recovery and local dry runs

If Apple is still processing after five minutes, repeat the packaging command
with `--resume` (do not repeat tag creation). The original DMG and submission ID
are retained in `dist/.vVERSION.pending/`. If an upload failed before an ID was
saved, inspect Apple history before resubmitting. Rejected builds require a fix
and a new candidate. After a publication network error, recheck the existing
release instead of replacing its assets.

For a local packaging test without Developer ID or notarization:

```sh
python3 scripts/prepare-desktop-release.py \
  --version "$VERSION" --build-number 1 \
  --output-dir "dist/$VERSION-candidate" --adhoc
```

These `UNSIGNED` candidates are not eligible for distribution. Keep this runbook
updated with changes to the scripts or supported platforms; keep per-release QA
and measurements with that release's evidence.
