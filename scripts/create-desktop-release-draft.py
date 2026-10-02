#!/usr/bin/env python3
"""Upload a verified Developer ID desktop package set to a GitHub draft release.

This never publishes the release. A release owner reviews QA and publishes the
draft in GitHub after checking the downloaded assets.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify(directory: Path) -> tuple[str, list[Path]]:
    manifest = json.loads((directory / "release-manifest.json").read_text())
    version, revision = manifest["version"], manifest["sourceRevision"]
    if manifest.get("mode") != "developer-id-notarized":
        raise ValueError("Only Developer ID signed and notarized packages can be uploaded")
    if len(manifest.get("artifacts", [])) != 2 or not all(
            item.get("publicDownload") is True for item in manifest["artifacts"]):
        raise ValueError("Manifest does not mark both artifacts as public downloads")
    tag = f"refs/tags/v{version}"
    if git("cat-file", "-t", tag) != "tag" or git("rev-parse", f"{tag}^{{commit}}") != revision:
        raise ValueError("Local annotated release tag does not match the packaged source")
    if git("status", "--porcelain"):
        raise ValueError("Publish from a clean checkout")
    if git("rev-parse", "HEAD") != revision:
        raise ValueError("Checkout does not match the packaged source")
    assets = []
    for item in manifest["artifacts"]:
        if "/" in item["name"] or "\\" in item["name"]:
            raise ValueError("Artifact name must be a file in the release directory")
        path = directory / item["name"]
        if not path.is_file() or path.stat().st_size != item["bytes"] or sha256(path) != item["sha256"]:
            raise ValueError(f"Artifact differs from manifest: {path}")
        assets.append(path)
    dmg = [path for path in assets if path.suffix == ".dmg" and "UNSIGNED" not in path.name]
    archive = [path for path in assets if path.name.endswith(".tar.gz")]
    if len(dmg) != 1 or len(archive) != 1:
        raise ValueError("Expected one signed Mac DMG and one Omarchy archive")
    subprocess.run(["/usr/bin/xcrun", "stapler", "validate", str(dmg[0])], check=True)
    subprocess.run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context",
                    "context:primary-signature", str(dmg[0])], check=True)
    checksums = (directory / "SHA256SUMS").read_text().splitlines()
    checked = set()
    for line in checksums:
        checksum, marker, name = line.partition("  ")
        if marker != "  " or not name or "/" in name or "\\" in name or name in checked:
            raise ValueError(f"Invalid SHA256SUMS entry: {line}")
        path = directory / name
        if not path.is_file() or sha256(path) != checksum:
            raise ValueError(f"SHA256SUMS mismatch: {name}")
        checked.add(name)
    required = {item["name"] for item in manifest["artifacts"]}
    required.update({"release-manifest.json", "RELEASE-NOTES.md"})
    if checked != required:
        raise ValueError("SHA256SUMS does not cover exactly the two artifacts, manifest, and notes")
    return version, assets


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release_dir", type=Path)
    args = parser.parse_args()
    try:
        directory = args.release_dir.expanduser().resolve(strict=True)
        version, assets = verify(directory)
        subprocess.run(["gh", "auth", "status"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["gh", "release", "create", f"v{version}", "--draft", "--prerelease",
                        "--verify-tag", "--title", f"Paceman desktop v{version}",
                        "--notes-file", str(directory / "RELEASE-NOTES.md"),
                        *map(str, [*assets, directory / "SHA256SUMS",
                                   directory / "release-manifest.json"])],
                       cwd=ROOT, check=True)
        print("Draft created. Review QA and downloaded assets before publishing it.")
    except (OSError, KeyError, TypeError, ValueError, subprocess.CalledProcessError,
            json.JSONDecodeError) as error:
        parser.exit(1, f"Desktop draft upload refused: {error}\n")


if __name__ == "__main__":
    main()
