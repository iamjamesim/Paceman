#!/usr/bin/env python3
"""Prepare, stage, check, and publish the same desktop release artifacts.

Signing runs on the release Mac using its Keychain. GitHub is the artifact
host. Human QA is recorded against SHA256SUMS; publishing never rebuilds.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "iamjamesim/paceman"
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


def verify(directory, *, platform_checks=True):
    """Verify source identity, every upload, and the notarized container."""
    entries = checksum_entries(directory)
    manifest = json.loads((directory / "release-manifest.json").read_text())
    version, revision = manifest["version"], manifest["sourceRevision"]
    if not VERSION.fullmatch(version) or not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ValueError("Invalid release version or source revision")
    if manifest.get("mode") != "developer-id-notarized":
        raise ValueError("Only Developer ID signed and notarized packages can be staged")
    expected_artifacts = {f"Paceman-Omarchy-{version}.tar.gz",
                          f"Paceman-macos-arm64-{version}.dmg"}
    artifacts = manifest.get("artifacts", [])
    if (len(artifacts) != 2 or {item["name"] for item in artifacts} != expected_artifacts
            or not all(item.get("publicDownload") is True for item in artifacts)):
        raise ValueError("Manifest must identify exactly the two public desktop artifacts")
    required = expected_artifacts | {"release-manifest.json", "RELEASE-NOTES.md"}
    if set(entries) != required:
        raise ValueError("SHA256SUMS must cover exactly both artifacts, manifest, and notes")
    for item in artifacts:
        path = directory / item["name"]
        if item["sha256"] != entries[path.name] or item["bytes"] != path.stat().st_size:
            raise ValueError(f"Artifact differs from manifest: {path.name}")
    tag = f"refs/tags/v{version}"
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
    return manifest, sorted(required | {"SHA256SUMS"})


def github_preflight():
    run("gh", "auth", "status")
    repository = gh("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]
    if repository != REPOSITORY:
        raise ValueError(f"Expected GitHub repository {REPOSITORY}, found {repository}")
    remote = output("git", "remote", "get-url", "origin")
    if remote not in (f"https://github.com/{REPOSITORY}", f"https://github.com/{REPOSITORY}.git",
                      f"git@github.com:{REPOSITORY}.git", f"git@github.com:{REPOSITORY}"):
        raise ValueError("origin must point to the release repository on GitHub")


def remote_tag(version, revision, *, push=False):
    tag = f"refs/tags/v{version}"
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
    tag = f"v{args.version}"
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
    run(*command)
    write_json(directory / "ci-evidence.json", checks[0])
    print(f"Prepared {directory}. Next: stage, test the downloaded artifacts, record QA, then publish.")


def releases():
    return gh("release", "list", "--repo", REPOSITORY, "--limit", "100",
              "--json", "tagName,isDraft,isPrerelease")


def release_view(version):
    return gh("release", "view", f"v{version}", "--repo", REPOSITORY,
              "--json", "tagName,isDraft,isPrerelease,url,assets")


def download_check(directory, manifest, names):
    release = release_view(manifest["version"])
    if {asset["name"] for asset in release["assets"]} != set(names):
        raise ValueError("Remote assets do not match the complete expected release set")
    destination = Path(tempfile.mkdtemp(prefix="downloaded-", dir=directory))
    run("gh", "release", "download", f"v{manifest['version']}", "--repo", REPOSITORY,
        "--dir", destination)
    for name in names:
        if sha256(destination / name) != sha256(directory / name):
            raise ValueError(f"Downloaded release asset differs: {name}")
    verify(destination)
    write_json(directory / "download-verification.json", {
        "checksumsSHA256": sha256(directory / "SHA256SUMS"), "directory": str(destination),
        "checkedAt": datetime.now(timezone.utc).isoformat(), "url": release["url"],
    })
    print(f"Downloaded assets verified. Use these exact files for installation QA: {destination}")


def stage(directory):
    manifest, names = verify(directory)
    github_preflight()
    version = manifest["version"]
    tag = f"v{version}"
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
        run("gh", "release", "create", tag, "--repo", REPOSITORY, "--draft", "--prerelease",
            "--verify-tag", "--title", f"Paceman desktop v{version}",
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


def require_qa(record, *, previous_releases):
    for name in QA_CHECKS:
        check = record.get("checks", {}).get(name, {})
        result = check.get("result")
        first_upgrade = name in UPGRADE_CHECKS and not previous_releases and result == "not-applicable"
        if (result != "passed" and not first_upgrade) or not check.get("notes", "").strip():
            raise ValueError(f"Release QA incomplete: {name} — {QA_CHECKS[name]}")


def publish(directory):
    manifest, names = verify(directory)
    github_preflight()
    version = manifest["version"]
    remote_tag(version, manifest["sourceRevision"])
    previous = [item for item in releases() if not item["isDraft"] and item["tagName"] != f"v{version}"]
    require_qa(qa_record(directory), previous_releases=previous)
    download_check(directory, manifest, names)
    release = release_view(version)
    if release["isDraft"]:
        # Stable releases need a separate updater/readiness decision, per the runbook.
        run("gh", "release", "edit", f"v{version}", "--repo", REPOSITORY,
            "--draft=false", "--prerelease", "--latest=false")
    elif not release["isPrerelease"]:
        raise ValueError("Expected an alpha/beta prerelease; refusing to alter a stable release")
    download_check(directory, manifest, names)
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
    build.add_argument("--resume", action="store_true")
    for name in ("stage", "verify", "status", "qa", "publish"):
        sub = commands.add_parser(name)
        sub.add_argument("directory", type=lambda value: Path(value).expanduser().resolve())
        if name == "qa":
            sub.add_argument("--check", choices=QA_CHECKS, required=True)
            sub.add_argument("--result", choices=("passed", "failed", "not-applicable"), required=True)
            sub.add_argument("--notes", required=True)
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
            publish(args.directory)
        else:
            verify(args.directory)
            record = qa_record(args.directory)
            for name, explanation in QA_CHECKS.items():
                print(f"{name}: {record['checks'].get(name, {}).get('result', 'pending')} — {explanation}")
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Desktop release stopped: {error}\n")


if __name__ == "__main__":
    main()
