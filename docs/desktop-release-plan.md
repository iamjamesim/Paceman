# Desktop release runbook

This document records distribution decisions and the steps for cutting a Mac
and Omarchy release. Keep candidate measurements and test evidence in the
generated release manifest, release notes, and PR; keep exact dependency
versions and hashes in the lock files. An ad hoc Mac DMG is for local
validation, not public distribution.

## Distribution decisions

| Platform | Customer delivery | Support floor |
| --- | --- | --- |
| Mac | A self-contained Apple Silicon DMG on GitHub Releases; a site download button may link to it. First launch installs to `~/Applications` and prepares the per-user background item and relay sender. | macOS 15.0+; test 15, 26, and 27 before the first release. |
| Omarchy | A versioned, checksum-verified source archive on the same desktop release. A copyable installer command and an optional “ask your agent to install” prompt can guide setup. | Omarchy 4.0+, user systemd session, distro-owned Python 3.11+. |

The Mac floor keeps the initial OS security and clean-install matrix
manageable; the current app APIs themselves can target earlier systems.
Apple Silicon keeps the first hardware matrix and binary to one architecture.
Lower the OS floor or add Intel only with measured demand and full install,
upgrade, and security QA. Revisit these choices after each macOS release.

GitHub Releases is sufficient hosting for the initial audience. Use one
annotated desktop tag for both assets and put their checksums and change notes
on the same release. A separate binary CDN needs evidence of a download
problem. The iPhone App Store/TestFlight release cadence is independent: test
new phone against old desktop and old phone against new desktop before a
phone update depends on a desktop capability.

Mac alpha updates use a newer DMG and preserve Application Support data.
Before a broad stable release, add signed Sparkle updates with separate alpha
and stable feeds, a user-visible update prompt, and rollback testing. Omarchy
updates rerun the newer archive. The Mac bundle ID remains
`dev.paceman.macos` and its source LaunchAgent remains `dev.paceman.source`;
the internal `dev.` text does not indicate a development signature. Changing
either ID after distribution would require a login-item/update migration.

## Package and trust boundaries

The Mac app bundles an arm64 `python-build-standalone` CPython runtime from
[`macos/python-runtime.json`](../macos/python-runtime.json) and the hash-locked
HTTP/1.1 relay client wheels from
[`requirements-client.txt`](../requirements-client.txt). Users do not install
Python, Homebrew, Xcode, or pip packages. Choose runtime patch updates after
dependency, OS, signing, and license checks; change Python minor versions
deliberately. The runtime includes native standard-library dependencies such
as OpenSSL, SQLite, and compression libraries even when Paceman does not call
every module. Track those when refreshing the runtime.

The ordinary Mac download does not include the optional direct-APNs packages
in [`requirements-push.txt`](../requirements-push.txt) or the hosted relay's
database/server packages in
[`requirements-relay.txt`](../requirements-relay.txt). The builder installs
client wheels and checks their hashes before signing. It rejects missing
license texts referenced by the Python build metadata. Review the actual
shipped files, licenses, dependency advisories, and generated component
manifest before each public release; hash locks are not vulnerability scans.

The public Mac DMG requires a **Developer ID Application** certificate for
team `ZTG42P5438`, hardened-runtime signatures on nested code and the app,
an Apple notary ticket, and stapling. Apple Development and ad hoc signatures
are local-development tools. Record Xcode/SDK, source commit, runtime and
wheel hashes, artifact hashes, signing evidence, and notarization result.
Signing credentials and APNs keys stay outside Git and the download.

Paceman uses a private Tailscale Serve HTTPS route to a loopback source;
Funnel remains off. The user must review Codex hooks. On Mac, review all
eight Paceman rows in **Codex Settings → Hooks → User config (All projects)**,
compare the expanded command with the installed command, then verify that a
fresh local task advances `lastAgentEventAt`. Pairing alone does not enable
monitoring. For iPhone alerts, separately verify the sender, APNs acceptance,
and a new notification displayed on a physical phone. Follow the complete
[Mac installation guide](../macos/README.md),
[Omarchy guide](../omarchy/README.md),
[architecture](architecture.md), and [data lifecycle](data-lifecycle.md).

## Prepare a local candidate

From a clean commit on an Apple Silicon Mac:

```sh
VERSION=0.1.0-alpha.1
python3 scripts/prepare-desktop-release.py \
  --version "$VERSION" --build-number 1 \
  --output-dir "dist/$VERSION-candidate" --adhoc
```

The command builds both packages from the same commit and verifies the
Omarchy archive, mounted Mac bundle, arm64 executables, embedded source
revision, code signature, and checksums. It writes `release-manifest.json`,
`SHA256SUMS`, and draft notes. The Mac filename includes `UNSIGNED` and the
manifest marks **both** candidate assets as ineligible for public upload.
`dist/` is ignored by Git; candidate files do not enter repository history.

## Build and stage the public release

After review and passing CI, create an annotated `vVERSION` tag on the chosen
commit. On a trusted release Mac with the Developer ID identity and a stored
`notarytool` profile, use a clean checkout of that exact tag:

```sh
VERSION=0.1.0-alpha.1
python3 scripts/prepare-desktop-release.py \
  --version "$VERSION" --build-number 1 --output-dir "dist/v$VERSION" \
  --identity "$PACEMAN_DEVELOPER_ID_APPLICATION" \
  --notary-profile paceman-release
```

The production path refuses a dirty checkout, missing or lightweight tag,
wrong Developer ID team, missing notary profile, invalid package, or existing
output directory. It signs, notarizes, staples, and verifies the DMG, then
writes the two assets, release notes, manifest, and checksums. The exact
certificate identity and notary credentials are local secrets, not repo
settings. With the tag pushed and GitHub CLI authenticated, create a draft:

```sh
python3 scripts/create-desktop-release-draft.py "dist/v$VERSION"
```

The draft command rechecks the tag, source revision, hashes, stapled ticket,
and Gatekeeper assessment. It refuses an ad hoc candidate and never publishes
the release. The release owner publishes after reviewing the downloaded
assets and completing the release gate below.

## Release gate

1. Run portable and Mac/iOS CI, the candidate package build, Omarchy archive
   extraction, and checksum verification. Record results with the candidate.
2. On clean standard-user installations of macOS 15, 26, and 27, check fresh
   install and upgrade, the Paceman Login Items entry, Sharing off/on, private
   route, reviewed hooks and real Codex event, pairing, physical-phone alert,
   restart, and uninstall. Review connected, empty, stale, and multiple-phone
   menu states at normal and accessibility text sizes.
3. Check the shipped dependency and license inventory, relevant advisories,
   retained user data across upgrade, and recovery after failed update. Test
   new phone with old desktop and old phone with new desktop.
4. Verify a freshly downloaded public DMG under Gatekeeper, then install from
   that download. Verify published archive/checksum URLs and the install path.
   Keep signing/notarization logs and the generated manifest with the release.
5. Publish the GitHub prerelease only after a release owner reviews the
   artifacts and known limitations. Explain manual Mac alpha updates. Hold a
   broad stable release until integrated updates and cross-version QA pass.

## Maintenance

Update this runbook when distribution, support floors, signing, or update
policy changes. Update the runtime and wheel lock files when dependencies
change; the preparation command copies their exact versions and hashes into
each release manifest. Put per-release measurements, QA results, and open
issues in that release's records rather than editing this runbook after every
build. Review this document and the package scripts together before each
desktop tag.
