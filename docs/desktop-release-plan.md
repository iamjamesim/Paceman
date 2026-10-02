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
problem. Releases in a private repository require repository access; a public
download link needs a public distribution repository or another public host.
The current scripts target `iamjamesim/paceman`; they never change its visibility.
The iPhone App Store/TestFlight release cadence is independent: test
new phone against old desktop and old phone against new desktop before a
phone update depends on a desktop capability.

Mac alpha updates use a newer DMG and preserve Application Support data.
Before a broad stable release, add signed Sparkle updates with separate alpha
and stable feeds, a user-visible update prompt, and rollback testing. Omarchy
updates rerun the newer archive. The public Mac bundle ID is
`ai.paceman.macos`, matching the iPhone app's `ai.paceman` namespace. The
per-user source LaunchAgent is `ai.paceman.source`. Freeze these identities
after first distribution. Before fresh-install QA on a Mac used for development,
uninstall its older development copy with that copy's own uninstaller.

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
The builder removes pip after installing those wheels; customers do not need
a package manager inside the app.

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

Use the same scripts whether the operator is a maintainer or an agent. The
trusted release Mac holds the signing identity and notarization credentials
in Keychain; GitHub Actions runs the existing portable and Mac/iOS checks.
The operator reviews the change notes and actual device results. No release
job may infer hook trust or physical notification display from unit tests.

After merging, use a clean checkout of the chosen commit. Authenticate once
with `gh auth login`. Write concise customer-facing change notes to a local
file; an agent can draft them from the merged changes for owner review. Run:

```sh
VERSION=0.1.0-alpha.1
python3 scripts/desktop_release.py prepare "$VERSION" \
  --build-number 1 --notes-file /tmp/paceman-release-notes.md
```

This preflights GitHub authentication, successful `Checks` on the exact commit,
and Apple credentials before packaging. It creates or verifies the local
annotated tag, builds both clients, signs nested code and the DMG, submits to
Apple, staples, verifies, and writes notes, manifest, and checksums. Set
`--identity` or `PACEMAN_DEVELOPER_ID_APPLICATION` only if the Mac has more than
one valid Developer ID identity for this team. The default notary profile is
`paceman-release`. Build numbers must increase between public builds.

Pending output is retained in `dist/.vVERSION.pending/`, including the original
submitted DMG, submission ID, and Apple log. If Apple takes more than five
minutes, repeat the **same prepare command with `--resume`**; it resumes that
submission without rebuilding or uploading again. A failed upload with no
saved submission ID requires inspecting Apple history before another submission.
Rejected builds require a fix and a new version/tag; never move a public tag.
All artifacts and evidence stay under ignored `dist/`.

Stage a draft and check the actual downloads:

```sh
python3 scripts/desktop_release.py stage "dist/v$VERSION"
```

This pushes the matching annotated tag, creates a GitHub draft prerelease,
uploads both assets, notes, manifest and checksums, then downloads every asset
and verifies its bytes and Gatekeeper assessment. Interrupted uploads can be
resumed by repeating `stage`; existing assets must match and are never replaced.
Test the printed `downloaded-*` directory. Both creation and publication refuse
ad hoc packages, dirty checkouts, differing tags, and mismatched checksums.

Record observed QA after testing, with device/OS versions and results:

```sh
python3 scripts/desktop_release.py status "dist/v$VERSION"
python3 scripts/desktop_release.py qa "dist/v$VERSION" \
  --check mac-fresh --result passed --notes 'Actual observed result and OS version'
```

`status` lists the required checks. Record failures as `failed`. Only the two
upgrade checks may be `not-applicable`, with an explanation, and publication
accepts that only when no prior public release exists. Other device checks
remain required. QA is bound to the checksums of these exact packages and notes;
it cannot be reused after rebuilding or editing them.

Once QA and the release notes are approved, publish the already-tested bytes:

```sh
python3 scripts/desktop_release.py publish "dist/v$VERSION"
```

Publication checks all QA, tag identity, and freshly downloaded assets before
making the draft public, then checks the downloads again. It always publishes
a prerelease and never rebuilds or marks it as the latest stable release. If a
post-publication network check fails, rerun `verify` or `publish` to check again;
do not replace the public assets. The older `create-desktop-release-draft.py`
command delegates to `stage` for compatibility. Lower-level packaging scripts
remain available for CI/local dry runs; they do not replace the release gate.

## Release gate

1. Run portable and Mac/iOS CI, the candidate package build, Omarchy archive
   extraction, and checksum verification. Record results with the candidate.
2. On clean standard-user installations of macOS 15, 26, and 27, check fresh
   install and an upgrade between public bundle builds, the Paceman Login Items
   entry, Sharing off/on, private
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

For releases with existing users, test the upgrade from the previous public
build **before uninstalling anything**, using representative pairings and
settings. Then test a fresh install in a separate standard-user account or VM.
That preserves upgrade evidence and independently checks onboarding. The first
public release has no previous public version; fresh install is its starting
point. Do not erase the developer's working installation to manufacture a
clean test environment without agreeing on removal of its pairing data.

## Maintenance

Update this runbook when distribution, support floors, signing, or update
policy changes. Update the runtime and wheel lock files when dependencies
change; the preparation command copies their exact versions and hashes into
each release manifest. Put per-release measurements, QA results, and open
issues in that release's records rather than editing this runbook after every
build. Review this document and the package scripts together before each
desktop tag.
