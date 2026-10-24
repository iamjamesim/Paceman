#!/usr/bin/env python3
"""Prepare, stage, check, and publish the same desktop release artifacts.

Signing runs on the release Mac using its Keychain. GitHub is the artifact
host. Human QA is recorded against SHA256SUMS; candidate trials also bind immutable
release/asset identities and the public test feed. Promotion never rebuilds.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import plistlib
import shutil
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

if __package__:
    from . import sparkle_dependency
else:
    import sparkle_dependency

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "iamjamesim/Paceman"
VERSION = re.compile(r"\d+\.\d+\.\d+(?:-alpha\.\d+|-beta\.\d+)?")
QA_CHECKS = {
    "mac-fresh": "Fresh standard-user install; Gatekeeper, login item, and menu",
    "mac-upgrade": "Upgrade prior public build; retain pairings, settings, and Sharing",
    "hooks-and-phone": "User-reviewed hooks, real Codex event, APNs acceptance, physical iPhone alert",
    "mac-recovery": "Sharing off/on, restart/reconnect, failed-update recovery, and uninstall",
    "macos-matrix": "Install and launch on macOS 15, 26, and 27; record tested versions",
    "omarchy-fresh": "Install archive on Omarchy; hooks, source, panel, and phone delivery",
    "omarchy-upgrade": "Update prior public archive; retain user data and unrelated hooks",
    "phone-compatibility": "Record TestFlight versions and old/new desktop compatibility",
}
UPGRADE_CHECKS = {"mac-upgrade", "omarchy-upgrade"}
UPDATER_QA_CHECKS = {
    "mac-signed-update": "Isolated signed test-feed update; preserve identity, pairings, choices, and history",
    "mac-signed-recovery": "Signed update busy deferral, cancellation, relaunch, and failed-handoff recovery",
}
FEED_HOST = "updates.paceman.ai"
FEED_BASE_URL = f"https://{FEED_HOST}"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), cwd=ROOT, check=True, **kwargs)


def output(*args):
    return run(*args, capture_output=True, text=True).stdout.strip()


def gh(*args):
    return json.loads(output("gh", *args))


def sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def checksum_entries(directory):
    entries = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        digest, separator, name = line.partition("  ")
        if (separator != "  " or not re.fullmatch(r"[a-f0-9]{64}", digest)
                or not name or name in (".", "..") or "/" in name or "\\" in name
                or name in entries):
            raise ValueError("Invalid or duplicate SHA256SUMS entry")
        path = directory / name
        if path.is_symlink() or not path.is_file() or sha256(path) != digest:
            raise ValueError(f"Checksum mismatch: {name}")
        entries[name] = digest
    return entries


def verify(directory, *, platform_checks=True, manifest=None):
    """Verify public assets against the local build manifest and release source."""
    entries = checksum_entries(directory)
    if manifest is None:
        manifest = json.loads((directory / "release-manifest.json").read_text())
    version, revision = manifest["version"], manifest["sourceRevision"]
    if not VERSION.fullmatch(version) or not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ValueError("Invalid release version or source revision")
    if manifest.get("mode") != "developer-id-notarized":
        raise ValueError("Only Developer ID signed and notarized packages can be staged")
    if manifest.get("updater") is not None:
        sparkle_dependency.public_update_settings(manifest["updater"])
        if (manifest.get("sparkleLockSHA256") != sha256(ROOT / "macos/sparkle.json")
                or not isinstance(manifest.get("buildNumber"), int) or manifest["buildNumber"] < 1):
            raise ValueError("Updater provenance must match the pinned Sparkle and positive build number")
    elif manifest.get("updaterConfigSHA256"):
        raise ValueError("Updater-enabled manifest is missing its public updater configuration; prepare again")
    expected_artifacts = {f"Paceman-Omarchy-{version}.tar.gz",
                          f"Paceman-macos-arm64-{version}.dmg"}
    artifacts = manifest.get("artifacts", [])
    if (len(artifacts) != 2 or {item["name"] for item in artifacts} != expected_artifacts
            or not all(item.get("publicDownload") is True for item in artifacts)):
        raise ValueError("Manifest must identify exactly the two public desktop artifacts")
    if set(entries) != expected_artifacts:
        raise ValueError("SHA256SUMS must cover exactly the two desktop artifacts")
    for item in artifacts:
        path = directory / item["name"]
        if item["sha256"] != entries[path.name] or item["bytes"] != path.stat().st_size:
            raise ValueError(f"Artifact differs from manifest: {path.name}")
    tag = f"refs/tags/desktop-v{version}"
    if (output("git", "cat-file", "-t", tag) != "tag"
            or output("git", "rev-parse", f"{tag}^{{commit}}") != revision
            or output("git", "rev-parse", "HEAD") != revision):
        raise ValueError("Clean checkout and annotated tag must match the packaged source")
    if output("git", "status", "--porcelain"):
        raise ValueError("Release checkout has uncommitted changes")
    if platform_checks:
        verify_embedded_settings(directory, manifest)
        dmg = directory / f"Paceman-macos-arm64-{version}.dmg"
        run("/usr/bin/xcrun", "stapler", "validate", dmg)
        run("/usr/sbin/spctl", "--assess", "--type", "open", "--context",
            "context:primary-signature", dmg)
    return manifest, sorted(expected_artifacts | {"SHA256SUMS"})


def verify_embedded_settings(directory, manifest):
    """Read the actual sealed bundle, rather than trusting the sidecar manifest."""
    dmg = directory / f"Paceman-macos-arm64-{manifest['version']}.dmg"
    with tempfile.TemporaryDirectory(prefix="paceman-release-bundle-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        run("/usr/bin/hdiutil", "attach", "-quiet", "-readonly", "-nobrowse",
            "-mountpoint", mount, dmg)
        try:
            app = mount / "Paceman.app"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            expected = {"CFBundleIdentifier": "ai.paceman.macos",
                        "CFBundleShortVersionString": manifest["version"].split("-")[0],
                        "CFBundleVersion": str(manifest["buildNumber"])}
            updater = sparkle_dependency.public_update_settings(manifest["updater"]) if manifest.get("updater") else {}
            for key in ("SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed",
                        "SUVerifyUpdateBeforeExtraction", "SUAllowsAutomaticUpdates",
                        "SUSignedFeedFailureExpirationInterval", "SUEnableAutomaticChecks",
                        "SUEnableSystemProfiling", "SUAutomaticallyUpdate"):
                expected[key] = updater.get(key)
            if any(info.get(key) != value for key, value in expected.items()):
                raise ValueError("Mac embedded version/build/updater settings differ from release manifest")
            build = json.loads((app / "Contents/Resources/lib/build-info.json").read_text())
            if build.get("sourceRevision") != manifest["sourceRevision"] or build.get("release") != manifest["version"]:
                raise ValueError("Mac embedded source differs from release manifest")
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        finally:
            run("/usr/bin/hdiutil", "detach", "-quiet", mount)


def github_preflight():
    run("gh", "auth", "status")
    repository = gh("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]
    if repository.casefold() != REPOSITORY.casefold():
        raise ValueError(f"Expected GitHub repository {REPOSITORY}, found {repository}")
    remote = output("git", "remote", "get-url", "origin")
    slug = REPOSITORY.casefold()
    if remote.casefold() not in (f"https://github.com/{slug}", f"https://github.com/{slug}.git",
                                f"git@github.com:{slug}.git", f"git@github.com:{slug}"):
        raise ValueError("origin must point to the release repository on GitHub")


def remote_tag(version, revision, *, push=False):
    tag = f"refs/tags/desktop-v{version}"
    remote = output("git", "ls-remote", "origin", tag, tag + "^{}")
    refs = dict(line.split()[::-1] for line in remote.splitlines())
    if not refs and push:
        run("git", "push", "origin", f"{tag}:{tag}")
        return remote_tag(version, revision)
    if (refs.get(tag + "^{}") != revision
            or refs.get(tag) != output("git", "rev-parse", tag)):
        raise ValueError("Remote annotated tag is missing or differs from the local release tag")


def prepare(args):
    if not VERSION.fullmatch(args.version) or args.build_number < 1:
        raise ValueError("Use a numeric version with optional alpha/beta suffix and positive build number")
    if sys.platform != "darwin":
        raise ValueError("Prepare on the Apple Silicon release Mac")
    if output("git", "status", "--porcelain"):
        raise ValueError("Prepare from a clean checkout")
    if not args.notes_file.read_text().strip():
        raise ValueError("Review and supply nonempty user-facing release notes")
    github_preflight()
    revision = output("git", "rev-parse", "HEAD")
    checks = gh("run", "list", "--repo", REPOSITORY, "--workflow", "checks.yml",
                "--commit", revision, "--limit", "1", "--json", "status,conclusion,url,headSha")
    if (not checks or checks[0]["headSha"] != revision or checks[0]["status"] != "completed"
            or checks[0]["conclusion"] != "success"):
        raise ValueError("The Checks workflow must have succeeded on this exact commit")
    identity = args.identity or os.environ.get("PACEMAN_DEVELOPER_ID_APPLICATION")
    if not identity:
        identities = re.findall(r'"(Developer ID Application:[^"\n]+\(ZTG42P5438\))"',
                                output("security", "find-identity", "-v", "-p", "codesigning"))
        if len(identities) != 1:
            raise ValueError("Choose --identity; expected one valid Developer ID identity for ZTG42P5438")
        identity = identities[0]
    run("xcrun", "notarytool", "history", "--keychain-profile", args.notary_profile,
        "--output-format", "json", stdout=subprocess.DEVNULL)
    tag = f"desktop-v{args.version}"
    existing = output("git", "tag", "--list", tag)
    if existing:
        if (output("git", "cat-file", "-t", tag) != "tag"
                or output("git", "rev-parse", f"{tag}^{{commit}}") != revision):
            raise ValueError("Existing release tag differs; never move an existing release tag")
    else:
        run("git", "tag", "-a", tag, revision, "-m", f"Paceman desktop {args.version}")
    directory = (args.output_dir or ROOT / "dist" / tag).resolve()
    command = [sys.executable, ROOT / "scripts/prepare-desktop-release.py", "--version", args.version,
               "--build-number", str(args.build_number), "--output-dir", directory,
               "--identity", identity, "--notary-profile", args.notary_profile,
               "--notes-file", args.notes_file.resolve()]
    if args.resume:
        command.append("--resume")
    for name in ('sparkle_archive', 'updater_config'):
        if getattr(args, name, None):
            command += ['--' + name.replace('_', '-'), getattr(args, name).resolve()]
    run(*command)
    write_json(directory / "ci-evidence.json", checks[0])
    print(f"Prepared {directory}. Next: stage, test the downloaded artifacts, record QA, then publish.")


def releases():
    return gh("release", "list", "--repo", REPOSITORY, "--limit", "100",
              "--json", "tagName,isDraft,isPrerelease")


def release_view(version):
    return gh("release", "view", f"desktop-v{version}", "--repo", REPOSITORY,
              "--json", "tagName,isDraft,isPrerelease,url,assets,databaseId")


def download_check(directory, manifest, names):
    release = release_view(manifest["version"])
    if {asset["name"] for asset in release["assets"]} != set(names):
        raise ValueError("Remote assets do not match the complete expected release set")
    destination = Path(tempfile.mkdtemp(prefix="downloaded-", dir=directory))
    run("gh", "release", "download", f"desktop-v{manifest['version']}", "--repo", REPOSITORY,
        "--dir", destination)
    for name in names:
        if sha256(destination / name) != sha256(directory / name):
            raise ValueError(f"Downloaded release asset differs: {name}")
    verify(destination, manifest=manifest)
    write_json(directory / "download-verification.json", {
        "checksumsSHA256": sha256(directory / "SHA256SUMS"), "directory": str(destination),
        "checkedAt": datetime.now(timezone.utc).isoformat(), "url": release["url"],
    })
    print(f"Downloaded assets verified. Use these exact files for installation QA: {destination}")


def stage(directory, *, candidate=False):
    manifest, names = verify(directory)
    if candidate:
        require_candidate_settings(manifest)
        if (directory / "candidate.json").exists():
            checked_candidate(directory, manifest)
    github_preflight()
    version = manifest["version"]
    tag = f"desktop-v{version}"
    existing = next((item for item in releases() if item["tagName"] == tag), None)
    if existing and not existing["isDraft"]:
        raise ValueError("Release is already public; it cannot be replaced by staging")
    remote_tag(version, manifest["sourceRevision"], push=True)
    if existing:
        present = release_view(version)["assets"]
        with tempfile.TemporaryDirectory(prefix="paceman-draft-check-") as temporary:
            for asset in present:
                name = asset["name"]
                if name not in names:
                    raise ValueError(f"Unexpected draft asset: {name}")
                run("gh", "release", "download", tag, "--repo", REPOSITORY,
                    "--pattern", name, "--dir", temporary)
                if sha256(Path(temporary) / name) != sha256(directory / name):
                    raise ValueError(f"Draft has different bytes for {name}; refusing to overwrite")
        missing = set(names) - {asset["name"] for asset in present}
        if missing:
            run("gh", "release", "upload", tag, "--repo", REPOSITORY,
                *(directory / name for name in sorted(missing)))
    else:
        run("gh", "release", "create", tag, "--repo", REPOSITORY, "--draft",
            *(["--prerelease", "--latest=false"] if candidate else (["--prerelease"] if "-" in version else [])),
            "--verify-tag", "--title", f"Desktop {version}",
            "--notes-file", directory / "RELEASE-NOTES.md", *(directory / name for name in names))
    download_check(directory, manifest, names)
    if candidate:
        if existing:
            run("gh", "release", "edit", tag, "--repo", REPOSITORY, "--prerelease=true", "--latest=false")
        identity = candidate_identity(directory, manifest, release_view(version))
        path = directory / "candidate.json"
        if path.exists() and json.loads(path.read_text())["identity"] != identity:
            raise ValueError("Candidate identity changed; never replace candidate assets or move its tag")
        if not path.exists():
            write_json(path, {"identity": identity})
        print("Candidate draft verified. Record package QA, then use publish-test; drafts are not anonymous downloads.")


def qa_record(directory):
    current = sha256(directory / "SHA256SUMS")
    path = directory / "qa.json"
    record = json.loads(path.read_text()) if path.exists() else {
        "checksumsSHA256": current, "checks": {},
    }
    if record.get("checksumsSHA256") != current:
        raise ValueError("QA belongs to different artifacts; create new QA evidence for this candidate")
    return record


def record_qa(args):
    manifest, _ = verify(args.directory)
    downloaded = json.loads((args.directory / "download-verification.json").read_text())
    if downloaded.get("checksumsSHA256") != sha256(args.directory / "SHA256SUMS"):
        raise ValueError("Stage and verify the current downloads before recording installation QA")
    if not args.notes.strip():
        raise ValueError("Record observed results and tested OS/device versions in --notes")
    if args.result == "not-applicable" and args.check not in UPGRADE_CHECKS:
        raise ValueError("Only upgrade checks can be not applicable for the first public release")
    record = qa_record(args.directory)
    record["checks"][args.check] = {"result": args.result, "notes": args.notes,
                                   "recordedAt": datetime.now(timezone.utc).isoformat()}
    if (args.directory / "candidate.json").exists() and args.check in UPDATER_QA_CHECKS and args.result == "passed":
        candidate = checked_candidate(args.directory, manifest)
        check_public_trial(args.directory, manifest, candidate)
        record["checks"][args.check].update(candidateIdentity=identity_digest(candidate["identity"]),
                                             testFeedSHA256=candidate["testFeedSHA256"])
    write_json(args.directory / "qa.json", record)
    print(f"Recorded {args.check}: {args.result}")


def require_qa(record, *, previous_releases, updater=False):
    required = QA_CHECKS | (UPDATER_QA_CHECKS if updater else {})
    for name in required:
        check = record.get("checks", {}).get(name, {})
        result = check.get("result")
        first_upgrade = name in UPGRADE_CHECKS and not previous_releases and result == "not-applicable"
        if (result != "passed" and not first_upgrade) or not check.get("notes", "").strip():
            raise ValueError(f"Release QA incomplete: {name} — {required[name]}")


def feed_preflight(manifest, *, channel, pages_dir, sparkle_archive, account, approved):
    """No credential lookup or remote mutation until the opt-in is complete."""
    if not any((channel, pages_dir, sparkle_archive, account, approved)):
        if manifest.get("updater"):
            raise ValueError("Updater releases require the guarded feed staging options")
        return
    if (not approved or channel not in ("stable", "test") or not pages_dir
            or not sparkle_archive or not account or not manifest.get("updater")):
        raise ValueError("Feed staging needs --approve-feed-signing, channel, Pages checkout, pinned archive, account, and updater config")
    packaged_feed = manifest["updater"]["feedURL"]
    if (packaged_feed not in {f"{FEED_BASE_URL}/macos/{name}/appcast.xml" for name in ("stable", "test")}
            or (channel == "stable" and packaged_feed != f"{FEED_BASE_URL}/macos/stable/appcast.xml")):
        raise ValueError("Feed channel differs from the packaged updater configuration")
    if channel == "stable" and "-" in manifest["version"]:
        raise ValueError("Prereleases belong on the isolated test feed")
    pages_preflight(channel, pages_dir)


def pages_preflight(channel, pages_dir):
    pages_dir = Path(pages_dir).expanduser().resolve()
    if (output("git", "-C", pages_dir, "rev-parse", "--show-toplevel") != str(pages_dir)
            or output("git", "-C", pages_dir, "branch", "--show-current") != "gh-pages"
            or output("git", "-C", pages_dir, "remote", "get-url", "origin").casefold()
            not in (f"https://github.com/{REPOSITORY.casefold()}.git", f"git@github.com:{REPOSITORY.casefold()}.git")):
        raise ValueError("Use a separate gh-pages checkout of the public Paceman repository")
    cname = pages_dir / "CNAME"
    if (not (pages_dir / ".nojekyll").is_file() or cname.is_symlink()
            or not cname.is_file() or cname.read_text().strip() != FEED_HOST):
        raise ValueError("Review the Pages custom domain and .nojekyll before staging a feed")
    target = f"macos/{channel}/appcast.xml"
    changed = output("git", "-C", pages_dir, "diff", "--name-only", "HEAD").splitlines()
    untracked = output("git", "-C", pages_dir, "ls-files", "--others", "--exclude-standard").splitlines()
    if any(path != target for path in changed + untracked):
        raise ValueError("Pages checkout has unrelated changes")
    if any((pages_dir / path).is_symlink() for path in (
            "macos", f"macos/{channel}", target)):
        raise ValueError("Feed paths must not be symlinks")


def public_download_check(directory, manifest, names):
    """Check the anonymous HTTPS URLs the updater will actually use."""
    prefix = f"https://github.com/{REPOSITORY}/releases/download/desktop-v{manifest['version']}/"
    with tempfile.TemporaryDirectory(prefix="paceman-public-download-") as temporary:
        for name in names:
            path = Path(temporary) / name
            run("curl", "--disable", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                "--proto-redir", "=https", "--output", path, prefix + name)
            if sha256(path) != sha256(directory / name):
                raise ValueError(f"Public release asset differs: {name}")
    return prefix


def record_feed_staging(directory, manifest, channel, target):
    record = {
        "channel": channel, "path": str(target), "feedSHA256": sha256(target),
        "checksumsSHA256": sha256(directory / "SHA256SUMS"),
        "feedURL": f"{FEED_BASE_URL}/macos/{channel}/appcast.xml",
        "sourceRevision": manifest["sourceRevision"], "published": False,
        "notesSHA256": sha256(directory / "RELEASE-NOTES.md"),
    }
    write_json(directory / "feed-staging.json", record)
    write_json(directory / f"feed-{channel}-staging.json", record)


def atomic_copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
        pending = Path(stream.name)
    try:
        pending.write_bytes(source.read_bytes())
        pending.replace(target)
    finally:
        pending.unlink(missing_ok=True)


def verify_signed_feed(path, public_key, archive=None):
    """Public-only Ed25519 verification; never reads the signing Keychain."""
    data = path.read_bytes()
    footer = re.search(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?\Z", data)
    if not footer or int(footer[2]) != footer.start():
        raise ValueError("Missing or malformed signed-feed footer")
    request = {"publicKey": public_key, "feedPath": str(path),
               "feedLength": footer.start(), "feedSignature": footer[1].decode()}
    if archive is not None:
        items = ET.fromstring(data).findall("channel/item")
        matches = [item.find("enclosure") for item in items
                   if item.find("enclosure") is not None and
                   item.find("enclosure").get("url", "").endswith("/" + archive.name)]
        if len(matches) != 1:
            raise ValueError("Signed feed must identify the exact Mac archive once")
        request.update(archivePath=str(archive), archiveSignature=matches[0].get(f"{{{SPARKLE_NS}}}edSignature"))
    with tempfile.TemporaryDirectory(prefix="paceman-public-signature-") as temporary:
        instruction = Path(temporary) / "verification.json"
        write_json(instruction, request)
        run("/usr/bin/swift", ROOT / "scripts/verify-sparkle-signatures.swift", instruction)
    return ET.fromstring(data)


def feed_items(path, manifest):
    return verify_signed_feed(path, manifest["updater"]["publicEDKey"]).findall("channel/item")


def semantic_digest(element):
    # Ignore formatting/comments while retaining every item field, attribute and condition.
    normalized = ET.fromstring(ET.tostring(element))
    for node in normalized.iter():
        if len(node) and node.text and node.text.isspace():
            node.text = None
        if node.tail and node.tail.isspace():
            node.tail = None
    # Leading/trailing Markdown whitespace can change notes; preserve all leaf text.
    canonical = ET.canonicalize(ET.tostring(normalized, encoding="unicode"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def check_feed_item(item, directory, manifest):
    archive = directory / f"Paceman-macos-arm64-{manifest['version']}.dmg"
    enclosure = item.find("enclosure")
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/desktop-v{manifest['version']}/{archive.name}"
    if (item.findtext(f"{{{SPARKLE_NS}}}version") != str(manifest["buildNumber"])
            or item.findtext(f"{{{SPARKLE_NS}}}shortVersionString") != manifest["version"].split("-")[0]
            or enclosure is None or enclosure.get("url") != expected_url
            or enclosure.get("length") != str(archive.stat().st_size)
            or not enclosure.get(f"{{{SPARKLE_NS}}}edSignature")):
        raise ValueError("Existing feed build differs; use a new version and build")
    candidate_record = directory / "candidate.json"
    if candidate_record.exists():
        record = json.loads(candidate_record.read_text())
        if record.get("testFeedSHA256"):
            saved = directory / "candidate-appcast.xml"
            if sha256(saved) != record["testFeedSHA256"]:
                raise ValueError("Saved candidate feed changed; QA cannot be reused")
            reference = ET.parse(saved).findall("channel/item")
            if len(reference) != 1 or semantic_digest(item) != semantic_digest(reference[0]):
                raise ValueError("Existing feed build differs in signed item semantics; use a new version and build")


def check_feed_builds(path, directory, manifest):
    same = False
    for item in feed_items(path, manifest):
        build = int(item.findtext(f"{{{SPARKLE_NS}}}version", "0"))
        if build > manifest["buildNumber"]:
            raise ValueError("Never promote a lower build over a newer feed")
        if build == manifest["buildNumber"]:
            check_feed_item(item, directory, manifest)
            verify_signed_feed(path, manifest["updater"]["publicEDKey"],
                               directory / f"Paceman-macos-arm64-{manifest['version']}.dmg")
            if same:
                raise ValueError("Duplicate candidate build in signed feed")
            same = True
    return same


def stage_feed(directory, manifest, names, *, channel, pages_dir, sparkle_archive, account, isolated=False):
    """One official generator invocation; publish/Pages push remain separate."""
    prefix = public_download_check(directory, manifest, names)
    target = Path(pages_dir).expanduser().resolve() / "macos" / channel / "appcast.xml"
    notes_hash = sha256(directory / "RELEASE-NOTES.md")
    evidence_path = directory / f"feed-{channel}-staging.json"
    intent_path = directory / f"feed-{channel}-intent.json"
    binding = {"manifestSHA256": sha256(directory / "release-manifest.json"),
               "checksumsSHA256": sha256(directory / "SHA256SUMS"), "notesSHA256": notes_hash,
               "buildNumber": manifest["buildNumber"], "sourceRevision": manifest["sourceRevision"]}
    if target.exists() and check_feed_builds(target, directory, manifest):
        evidence = json.loads(evidence_path.read_text()) if evidence_path.exists() else {}
        intent = json.loads(intent_path.read_text()) if intent_path.exists() else {}
        known_bytes = evidence.get("notesSHA256") == notes_hash and evidence.get("feedSHA256") == sha256(target)
        recoverable = (intent.get("binding") == binding
                       and intent.get("semanticsSHA256") == semantic_digest(ET.parse(target).getroot()))
        if not known_bytes and not recoverable:
            raise ValueError("Existing feed build differs or has no matching local review evidence")
        record_feed_staging(directory, manifest, channel, target)
        return target
    with tempfile.TemporaryDirectory(prefix="paceman-feed-") as temporary:
        scratch = Path(temporary)
        tools = sparkle_dependency.framework(Path(sparkle_archive), scratch).parent / "bin"
        archives = scratch / "archives"
        archives.mkdir()
        mac = directory / f"Paceman-macos-arm64-{manifest['version']}.dmg"
        shutil.copyfile(mac, archives / mac.name)
        shutil.copyfile(directory / "RELEASE-NOTES.md", archives / mac.with_suffix(".md").name)
        candidate = archives / "appcast.xml"
        if target.exists() and not isolated:
            shutil.copyfile(target, candidate)
        run(tools / "generate_appcast", "--account", account, "--download-url-prefix", prefix,
            "--embed-release-notes", "--maximum-deltas", "0", "--maximum-versions", "0",
            "--versions", str(manifest["buildNumber"]), "-o", candidate, archives)
        root = verify_signed_feed(candidate, manifest["updater"]["publicEDKey"], mac)
        items = root.findall("channel/item")
        matched = [item for item in items if item.findtext(f"{{{SPARKLE_NS}}}version") == str(manifest["buildNumber"])]
        if len(matched) != 1 or (isolated and len(items) != 1):
            raise ValueError("Official generator did not produce the expected candidate item")
        check_feed_item(matched[0], directory, manifest)
        # Persist review intent BEFORE replacement, so a later evidence-write failure is retryable.
        write_json(intent_path, {"binding": binding, "semanticsSHA256": semantic_digest(root)})
        atomic_copy(candidate, target)
    record_feed_staging(directory, manifest, channel, target)
    print(f"Signed feed staged locally: {target}. Review its separate Pages commit/push; not published.")
    return target


def require_candidate_settings(manifest):
    if (not re.fullmatch(r"\d+\.\d+\.\d+", manifest["version"])
            or not manifest.get("updater")
            or manifest["updater"]["feedURL"] != f"{FEED_BASE_URL}/macos/stable/appcast.xml"):
        raise ValueError("Same-byte promotion needs a final numeric version with the embedded stable feed; alpha/beta cannot become stable")


def candidate_identity(directory, manifest, release):
    if release["tagName"] != f"desktop-v{manifest['version']}":
        raise ValueError("Candidate release tag differs")
    assets = []
    for asset in release["assets"]:
        if not asset.get("apiUrl"):
            raise ValueError("Candidate asset is missing its immutable GitHub identity")
        assets.append({key: asset[key] for key in ("name", "size", "apiUrl")})
    if not release.get("databaseId"):
        raise ValueError("Candidate release is missing its immutable GitHub identity")
    tag_object = output("git", "rev-parse", f"refs/tags/desktop-v{manifest['version']}")
    if not re.fullmatch(r"[a-f0-9]{40}", tag_object):
        raise ValueError("Candidate annotated tag identity is missing")
    return {"releaseId": release["databaseId"], "tag": release["tagName"], "tagObject": tag_object,
            "assets": sorted(assets, key=lambda asset: asset["name"]),
            "manifestSHA256": sha256(directory / "release-manifest.json"),
            "checksumsSHA256": sha256(directory / "SHA256SUMS"),
            "notesSHA256": sha256(directory / "RELEASE-NOTES.md")}


def identity_digest(identity):
    return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()


def checked_candidate(directory, manifest):
    require_candidate_settings(manifest)
    record = json.loads((directory / "candidate.json").read_text())
    if record["identity"] != candidate_identity(directory, manifest, release_view(manifest["version"])):
        raise ValueError("Candidate identity changed; do not replace assets, edit notes, or move tags")
    return record


def fetch_public_feed(channel, destination, *, allow_missing=False):
    """No authentication, cookies, curl config, HTTP downgrade, or cached local substitute."""
    url = f"{FEED_BASE_URL}/macos/{channel}/appcast.xml"
    response = run("curl", "--disable", "--silent", "--show-error", "--location", "--proto", "=https",
                   "--proto-redir", "=https", "--output", destination, "--write-out", "%{http_code}", url,
                   capture_output=True, text=True).stdout.strip()
    if response == "404" and allow_missing:
        return False
    if response != "200":
        raise ValueError(f"Public {channel} feed returned HTTP {response}; stop before publication")
    return True


def public_build_guard(directory, manifest):
    with tempfile.TemporaryDirectory(prefix="paceman-feed-order-") as temporary:
        for channel in ("test", "stable"):
            path = Path(temporary) / f"{channel}.xml"
            if fetch_public_feed(channel, path, allow_missing=True):
                check_feed_builds(path, directory, manifest)


def check_saved_trial(directory, manifest, record):
    saved = directory / "candidate-appcast.xml"
    if not record.get("testFeedSHA256") or sha256(saved) != record["testFeedSHA256"]:
        raise ValueError("Stage and publish the candidate test feed before recording signed-trial QA")
    items = verify_signed_feed(saved, manifest["updater"]["publicEDKey"],
                               directory / f"Paceman-macos-arm64-{manifest['version']}.dmg").findall("channel/item")
    if len(items) != 1:
        raise ValueError("Candidate feed must contain only the exact promotion candidate")
    check_feed_item(items[0], directory, manifest)


def check_public_trial(directory, manifest, record):
    check_saved_trial(directory, manifest, record)
    with tempfile.TemporaryDirectory(prefix="paceman-trial-feed-") as temporary:
        path = Path(temporary) / "appcast.xml"
        fetch_public_feed("test", path)
        if sha256(path) != record["testFeedSHA256"]:
            raise ValueError("Public test feed differs from this candidate; QA cannot be reused")


def prior_releases(version):
    return [item for item in releases() if not item["isDraft"]
            and item["tagName"].startswith("desktop-v") and item["tagName"] != f"desktop-v{version}"]


def publish_test(directory, *, pages_dir, sparkle_archive, keychain_account, approve_feed_signing):
    manifest, names = verify(directory)
    require_candidate_settings(manifest)
    feed_preflight(manifest, channel="test", pages_dir=pages_dir, sparkle_archive=sparkle_archive,
                   account=keychain_account, approved=approve_feed_signing)
    github_preflight()
    remote_tag(manifest["version"], manifest["sourceRevision"])
    record = checked_candidate(directory, manifest)
    require_qa(qa_record(directory), previous_releases=prior_releases(manifest["version"]))
    download_check(directory, manifest, names)
    public_build_guard(directory, manifest)
    release = release_view(manifest["version"])
    if not release["isDraft"] and not release["isPrerelease"]:
        raise ValueError("Already stable; never convert a stable release back to a test candidate")
    # A failed upload/signing step can be retried without uploading/replacing anything.
    run("gh", "release", "edit", f"desktop-v{manifest['version']}", "--repo", REPOSITORY,
        "--draft=false", "--prerelease=true", "--latest=false")
    checked_candidate(directory, manifest)
    download_check(directory, manifest, names)
    if record.get("testFeedSHA256"):
        # Reuse exact generated bytes even if the prior attempt stopped before the Pages push.
        check_saved_trial(directory, manifest, record)
        public_download_check(directory, manifest, names)
        target = Path(pages_dir).expanduser().resolve() / "macos/test/appcast.xml"
        if target.exists():
            check_feed_builds(target, directory, manifest)
        atomic_copy(directory / "candidate-appcast.xml", target)
        record_feed_staging(directory, manifest, "test", target)
    else:
        target = stage_feed(directory, manifest, names, channel="test", pages_dir=pages_dir,
                            sparkle_archive=sparkle_archive, account=keychain_account, isolated=True)
        atomic_copy(target, directory / "candidate-appcast.xml")
        record["testFeedSHA256"] = sha256(target)
        write_json(directory / "candidate.json", record)
    print("Public prerelease (not latest) verified. Test feed is LOCAL only; review/commit/push Pages separately.")


def promote(directory, *, pages_dir):
    manifest, names = verify(directory)
    require_candidate_settings(manifest)
    pages_preflight("stable", pages_dir)
    github_preflight()
    remote_tag(manifest["version"], manifest["sourceRevision"])
    record = checked_candidate(directory, manifest)
    qa = qa_record(directory)
    require_qa(qa, previous_releases=prior_releases(manifest["version"]), updater=True)
    check_public_trial(directory, manifest, record)
    for name in UPDATER_QA_CHECKS:
        check = qa["checks"][name]
        if (check.get("candidateIdentity") != identity_digest(record["identity"])
                or check.get("testFeedSHA256") != record["testFeedSHA256"]):
            raise ValueError(f"{name} is not bound to this exact candidate and public test feed")
    download_check(directory, manifest, names)
    public_download_check(directory, manifest, names)
    public_build_guard(directory, manifest)
    target = Path(pages_dir).expanduser().resolve() / "macos/stable/appcast.xml"
    if target.exists():
        check_feed_builds(target, directory, manifest)
    release = release_view(manifest["version"])
    if release["isDraft"]:
        raise ValueError("Publish and test the prerelease before promotion")
    # Only metadata changes. No build, signing, asset upload, or tag mutation here.
    run("gh", "release", "edit", f"desktop-v{manifest['version']}", "--repo", REPOSITORY,
        "--prerelease=false", "--latest=true")
    checked_candidate(directory, manifest)
    download_check(directory, manifest, names)
    public_download_check(directory, manifest, names)
    # Stable activation is deliberately last and remains a separately reviewed Pages push.
    atomic_copy(directory / "candidate-appcast.xml", target)
    record_feed_staging(directory, manifest, "stable", target)
    print("Same release/assets promoted; exact tested signed feed staged at stable. Review/commit/push Pages separately.")


def publish(directory, *, feed_channel=None, pages_dir=None, sparkle_archive=None,
            keychain_account=None, approve_feed_signing=False):
    manifest, names = verify(directory)
    pages_dir = Path(pages_dir).expanduser().resolve() if pages_dir else None
    feed_preflight(manifest, channel=feed_channel, pages_dir=pages_dir, sparkle_archive=sparkle_archive,
                   account=keychain_account, approved=approve_feed_signing)
    if (directory / "candidate.json").exists():
        raise ValueError("Use publish-test then promote for an explicitly staged candidate")
    github_preflight()
    version = manifest["version"]
    remote_tag(version, manifest["sourceRevision"])
    previous = [item for item in releases() if not item["isDraft"]
                and item["tagName"].startswith("desktop-v")
                and item["tagName"] != f"desktop-v{version}"]
    require_qa(qa_record(directory), previous_releases=previous,
               updater=bool(manifest.get("updater")) and feed_channel != "test")
    download_check(directory, manifest, names)
    release = release_view(version)
    if release["isDraft"]:
        run("gh", "release", "edit", f"desktop-v{version}", "--repo", REPOSITORY,
            "--draft=false", f"--prerelease={str('-' in version).lower()}")
    elif release["isPrerelease"] != ("-" in version):
        raise ValueError("Published release classification differs from its version")
    download_check(directory, manifest, names)
    if feed_channel:
        stage_feed(directory, manifest, names, channel=feed_channel, pages_dir=pages_dir,
                   sparkle_archive=sparkle_archive, account=keychain_account)
    print(release_view(version)["url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("prepare", help="Preflight CI/credentials, tag locally, build and notarize")
    build.add_argument("version")
    build.add_argument("--build-number", type=int, required=True)
    build.add_argument("--identity")
    build.add_argument("--notary-profile", default="paceman-release")
    build.add_argument("--output-dir", type=Path)
    build.add_argument("--notes-file", type=Path, required=True)
    build.add_argument("--sparkle-archive", type=Path)
    build.add_argument("--updater-config", type=Path, help="Public feedURL and publicEDKey only")
    build.add_argument("--resume", action="store_true")
    for name in ("stage", "verify", "status", "qa", "publish", "publish-test", "promote"):
        sub = commands.add_parser(name)
        sub.add_argument("directory", type=lambda value: Path(value).expanduser().resolve())
        if name == "stage":
            sub.add_argument("--candidate", action="store_true", help="Final-version prerelease, not latest; promote the same bytes later")
        if name == "promote":
            sub.add_argument("--pages-dir", type=Path, required=True)
        if name == "qa":
            sub.add_argument("--check", choices=QA_CHECKS | UPDATER_QA_CHECKS, required=True)
            sub.add_argument("--result", choices=("passed", "failed", "not-applicable"), required=True)
            sub.add_argument("--notes", required=True)
        if name == "publish":
            sub.add_argument("--feed-channel", choices=("stable", "test"))
        if name in ("publish", "publish-test"):
            sub.add_argument("--pages-dir", type=Path)
            sub.add_argument("--sparkle-archive", type=Path)
            sub.add_argument("--keychain-account")
            sub.add_argument("--approve-feed-signing", action="store_true",
                             help="Explicitly authorize Keychain signing; stages locally, never pushes Pages")
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args)
        elif args.command == "stage":
            stage(args.directory, candidate=args.candidate)
        elif args.command == "verify":
            manifest, names = verify(args.directory)
            github_preflight()
            remote_tag(manifest["version"], manifest["sourceRevision"])
            download_check(args.directory, manifest, names)
        elif args.command == "qa":
            record_qa(args)
        elif args.command == "promote":
            promote(args.directory, pages_dir=args.pages_dir)
        elif args.command == "publish-test":
            publish_test(args.directory, pages_dir=args.pages_dir, sparkle_archive=args.sparkle_archive,
                         keychain_account=args.keychain_account, approve_feed_signing=args.approve_feed_signing)
        elif args.command == "publish":
            publish(args.directory, feed_channel=args.feed_channel, pages_dir=args.pages_dir,
                    sparkle_archive=args.sparkle_archive, keychain_account=args.keychain_account,
                    approve_feed_signing=args.approve_feed_signing)
        else:
            manifest, _ = verify(args.directory)
            record = qa_record(args.directory)
            for name, explanation in (QA_CHECKS | (UPDATER_QA_CHECKS if manifest.get("updater") else {})).items():
                print(f"{name}: {record['checks'].get(name, {}).get('result', 'pending')} — {explanation}")
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Desktop release stopped: {error}\n")


if __name__ == "__main__":
    main()
