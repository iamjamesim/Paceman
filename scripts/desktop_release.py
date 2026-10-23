#!/usr/bin/env python3
"""Prepare, stage, check, and publish the same desktop release artifacts.

Signing runs on the release Mac using its Keychain. GitHub is the artifact
host. Human QA is recorded against SHA256SUMS; publishing never rebuilds.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import html
import json
import os
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
FEED_BASE_URL = "https://iamjamesim.github.io/Paceman/updates"
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
        dmg = directory / f"Paceman-macos-arm64-{version}.dmg"
        run("/usr/bin/xcrun", "stapler", "validate", dmg)
        run("/usr/sbin/spctl", "--assess", "--type", "open", "--context",
            "context:primary-signature", dmg)
    return manifest, sorted(expected_artifacts | {"SHA256SUMS"})


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
              "--json", "tagName,isDraft,isPrerelease,url,assets")


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


def stage(directory):
    manifest, names = verify(directory)
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
            *(["--prerelease"] if "-" in version else []),
            "--verify-tag", "--title", f"Desktop {version}",
            "--notes-file", directory / "RELEASE-NOTES.md", *(directory / name for name in names))
    download_check(directory, manifest, names)


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
    verify(args.directory)
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
    pages_dir = Path(pages_dir).expanduser().resolve()
    if (output("git", "-C", pages_dir, "rev-parse", "--show-toplevel") != str(pages_dir)
            or output("git", "-C", pages_dir, "branch", "--show-current") != "gh-pages"
            or output("git", "-C", pages_dir, "remote", "get-url", "origin").casefold()
            not in (f"https://github.com/{REPOSITORY.casefold()}.git", f"git@github.com:{REPOSITORY.casefold()}.git")):
        raise ValueError("Use a separate gh-pages checkout of the public Paceman repository")
    if (not (pages_dir / ".nojekyll").is_file() or (pages_dir / "CNAME").exists()):
        raise ValueError("Use the default GitHub Pages host with .nojekyll; review any custom-domain change separately")
    target = f"updates/macos/{channel}/appcast.xml"
    changed = output("git", "-C", pages_dir, "diff", "--name-only", "HEAD").splitlines()
    untracked = output("git", "-C", pages_dir, "ls-files", "--others", "--exclude-standard").splitlines()
    if any(path != target for path in changed + untracked):
        raise ValueError("Pages checkout has unrelated changes")
    if any((pages_dir / path).is_symlink() for path in (
            "updates", "updates/macos", f"updates/macos/{channel}", target)):
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
    write_json(directory / "feed-staging.json", {
        "channel": channel, "path": str(target), "feedSHA256": sha256(target),
        "checksumsSHA256": sha256(directory / "SHA256SUMS"),
        "feedURL": f"{FEED_BASE_URL}/macos/{channel}/appcast.xml",
        "sourceRevision": manifest["sourceRevision"], "published": False,
    })


def stage_feed(directory, manifest, names, *, channel, pages_dir, sparkle_archive, account):
    """Stage signed static bytes locally. Commit/push/Pages activation are separate approvals."""
    prefix = public_download_check(directory, manifest, names)
    target = Path(pages_dir).expanduser().resolve() / "updates" / "macos" / channel / "appcast.xml"
    notes = "<pre>" + html.escape((directory / "RELEASE-NOTES.md").read_text()) + "</pre>"
    with tempfile.TemporaryDirectory(prefix="paceman-feed-") as temporary:
        scratch = Path(temporary)
        tools = sparkle_dependency.framework(Path(sparkle_archive), scratch).parent / "bin"
        if output(tools / "generate_keys", "--account", account, "-p") != manifest["updater"]["publicEDKey"]:
            raise ValueError("Keychain publisher public key differs from the packaged key")
        mac = directory / f"Paceman-macos-arm64-{manifest['version']}.dmg"
        signature = output(tools / "sign_update", "--account", account, "-p", mac)
        run(tools / "sign_update", "--account", account, "--verify", mac, signature)
        if target.exists():
            run(tools / "sign_update", "--account", account, "--verify", target)
            feed = ET.parse(target).getroot()
            if feed.tag != "rss" or feed.find("channel") is None:
                raise ValueError("Existing feed is not an RSS appcast")
        else:
            feed = ET.Element("rss", {"version": "2.0"})
            container = ET.SubElement(feed, "channel")
            ET.SubElement(container, "title").text = "Paceman Mac updates"
        container = feed.find("channel")
        item = ET.Element("item")
        ET.SubElement(item, "title").text = f"Paceman {manifest['version']}"
        ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(manifest["buildNumber"])
        ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = manifest["version"].split("-")[0]
        ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "15.0"
        ET.SubElement(item, "description").text = notes
        ET.SubElement(item, "enclosure", {"url": prefix + mac.name, "length": str(mac.stat().st_size),
                      "type": "application/octet-stream", f"{{{SPARKLE_NS}}}edSignature": signature})
        for old in container.findall("item"):
            old_build = int(old.findtext(f"{{{SPARKLE_NS}}}version", "0"))
            if old_build > manifest["buildNumber"]:
                raise ValueError("Never promote a lower build over a newer feed")
            if old_build == manifest["buildNumber"]:
                if (any(old.findtext(child.tag) != child.text for child in item if child.tag != "enclosure")
                        or old.find("enclosure") is None
                        or old.find("enclosure").attrib != item.find("enclosure").attrib):
                    raise ValueError("Existing feed build differs; use a new version and build")
                record_feed_staging(directory, manifest, channel, target)
                print(f"Feed already staged: {target}. Not published.")
                return
        container.insert(1, item)
        candidate = scratch / "appcast.xml"
        ET.ElementTree(feed).write(candidate, encoding="utf-8", xml_declaration=True)
        run(tools / "sign_update", "--account", account, candidate)
        run(tools / "sign_update", "--account", account, "--verify", candidate)
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
            pending = Path(stream.name)
        try:
            pending.write_bytes(candidate.read_bytes())
            pending.replace(target)
        finally:
            pending.unlink(missing_ok=True)
        record_feed_staging(directory, manifest, channel, target)
    print(f"Signed feed staged locally: {target}. Review and approve its separate Pages commit/push; not published.")


def publish(directory, *, feed_channel=None, pages_dir=None, sparkle_archive=None,
            keychain_account=None, approve_feed_signing=False):
    manifest, names = verify(directory)
    pages_dir = Path(pages_dir).expanduser().resolve() if pages_dir else None
    feed_preflight(manifest, channel=feed_channel, pages_dir=pages_dir, sparkle_archive=sparkle_archive,
                   account=keychain_account, approved=approve_feed_signing)
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
    for name in ("stage", "verify", "status", "qa", "publish"):
        sub = commands.add_parser(name)
        sub.add_argument("directory", type=lambda value: Path(value).expanduser().resolve())
        if name == "qa":
            sub.add_argument("--check", choices=QA_CHECKS | UPDATER_QA_CHECKS, required=True)
            sub.add_argument("--result", choices=("passed", "failed", "not-applicable"), required=True)
            sub.add_argument("--notes", required=True)
        if name == "publish":
            sub.add_argument("--feed-channel", choices=("stable", "test"))
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
            stage(args.directory)
        elif args.command == "verify":
            manifest, names = verify(args.directory)
            github_preflight()
            remote_tag(manifest["version"], manifest["sourceRevision"])
            download_check(args.directory, manifest, names)
        elif args.command == "qa":
            record_qa(args)
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
