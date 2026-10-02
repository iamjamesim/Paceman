#!/usr/bin/env python3
"""Build and inspect both desktop artifacts in one immutable release directory.

--adhoc prepares a local candidate; the Mac DMG is never a public download.
Production requires an annotated exact tag, Developer ID, and notarization.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
VERSION_PATTERN = re.compile(r"\d+\.\d+\.\d+(?:-alpha\.\d+|-beta\.\d+)?")
MAC_BUNDLE_ID = "dev.paceman.macos"


def run(*args: str | Path, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def output(*args: str | Path) -> str:
    return subprocess.check_output(list(map(str, args)), cwd=ROOT, text=True).strip()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def source_revision(version: str, *, adhoc: bool) -> str:
    revision = output("git", "rev-parse", "HEAD")
    if output("git", "status", "--porcelain"):
        raise ValueError("Desktop packages require a clean checkout so both use the same source")
    if not adhoc:
        tag = f"refs/tags/v{version}"
        if output("git", "cat-file", "-t", tag) != "tag":
            raise ValueError(f"Public release requires annotated tag v{version}")
        if output("git", "rev-parse", f"{tag}^{{commit}}") != revision:
            raise ValueError(f"Tag v{version} does not point at HEAD")
    return revision


def verify_omarchy(archive: Path, version: str) -> None:
    prefix = f"Paceman-Omarchy-{version}/"
    required = {prefix + "scripts/install-omarchy.sh", prefix + "omarchy/install.py",
                prefix + "service/hub.py", prefix + "requirements-client.txt"}
    with tarfile.open(archive, "r:gz") as source:
        names = set()
        for item in source:
            if item.name == prefix.rstrip("/") and item.isdir():
                continue
            if not item.name.startswith(prefix) or ".." in Path(item.name).parts:
                raise ValueError(f"Unexpected Omarchy archive member: {item.name}")
            if item.issym() or item.islnk():
                raise ValueError(f"Symlink in Omarchy archive: {item.name}")
            names.add(item.name)
    if missing := required - names:
        raise ValueError(f"Omarchy archive is missing: {sorted(missing)}")


def verify_mac(dmg: Path, revision: str, version: str, build_number: int,
               runtime: dict) -> None:
    run("/usr/bin/hdiutil", "verify", "-quiet", dmg)
    with tempfile.TemporaryDirectory(prefix="paceman-verify-") as directory:
        mount = Path(directory) / "mount"
        mount.mkdir()
        run("/usr/bin/hdiutil", "attach", "-quiet", "-readonly", "-nobrowse",
            "-mountpoint", mount, dmg)
        try:
            app = mount / "Paceman.app"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            expected = {"CFBundleIdentifier": MAC_BUNDLE_ID,
                        "CFBundleShortVersionString": version.split("-")[0],
                        "CFBundleVersion": str(build_number),
                        "LSMinimumSystemVersion": "15.0", "LSUIElement": True}
            for key, value in expected.items():
                if info.get(key) != value:
                    raise ValueError(f"Mac bundle {key}: expected {value!r}, found {info.get(key)!r}")
            build = json.loads((app / "Contents/Resources/lib/build-info.json").read_text())
            if (build.get("sourceRevision") != revision or build.get("release") != version
                    or build.get("pythonVersion") != runtime["version"]
                    or build.get("pythonArchiveSHA256") != runtime["sha256"]):
                raise ValueError("Mac embedded build provenance does not match release inputs")
            for name in ("Paceman", "PacemanBackground"):
                architectures = subprocess.check_output(
                    ["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS" / name)],
                    text=True).split()
                if architectures != ["arm64"]:
                    raise ValueError(f"Unexpected {name} architectures: {architectures}")
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        finally:
            run("/usr/bin/hdiutil", "detach", "-quiet", mount)


def artifact(path: Path, *, public: bool) -> dict:
    return {"name": path.name, "bytes": path.stat().st_size, "sha256": digest(path),
            "publicDownload": public}


def client_wheels() -> list[dict]:
    packages = []
    for line in (ROOT / "requirements-client.txt").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([^\s]+) --hash=sha256:([a-f0-9]{64})", line)
        if not match:
            raise ValueError(f"Unexpected client dependency lock entry: {line}")
        name, version, sha256 = match.groups()
        packages.append({"name": name, "version": version, "wheelSHA256": sha256})
    if not packages:
        raise ValueError("Client dependency lock is empty")
    return packages


def release_notes(version: str, revision: str, files: list[dict], adhoc: bool) -> str:
    table = "\n".join(f"| `{item['name']}` | {item['bytes'] / 1_000_000:.1f} MB | `{item['sha256']}` |"
                      for item in files)
    status = ("LOCAL CANDIDATE ONLY — the Mac DMG is ad hoc signed and must not be uploaded."
              if adhoc else "Developer ID signed and notarized Mac release candidate.")
    return f"""# Paceman desktop {version}

{status}

Source commit: `{revision}`. Both desktop packages were built from this commit.

| Artifact | Size | SHA-256 |
| --- | ---: | --- |
{table}

## Mac

Apple Silicon, macOS 15 or newer. Download the DMG, open Paceman, and choose
**Install Paceman**. The app includes Python. Tailscale and Codex are separate
requirements. Review Paceman's eight hooks in Codex **Settings → Hooks → User
config (All projects)**, configure private Tailscale Serve, then pair the phone.
Check a fresh Codex event and a new notification on the physical iPhone.
Updates during alpha use a newer DMG; quit the running menu app first.

## Omarchy

Omarchy 4.0 or newer, Python 3.11 or newer, and a user systemd session.
Download the archive, verify it against `SHA256SUMS`, extract it, then run
`bash scripts/install-omarchy.sh` from the extracted directory. Review the
seven Codex hooks. Re-run a newer archive to update.

The iPhone version is released independently. See the installation READMEs
and desktop release plan for pairing, privacy, and compatibility details.
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--python-archive", type=Path)
    parser.add_argument("--wheelhouse", type=Path)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--adhoc", action="store_true")
    signing.add_argument("--identity", help="Developer ID Application identity")
    parser.add_argument("--notary-profile", help="Stored notarytool keychain profile")
    args = parser.parse_args()
    if not VERSION_PATTERN.fullmatch(args.version) or args.build_number < 1:
        parser.error("Specify a valid desktop version and a positive build number")
    if bool(args.identity) != bool(args.notary_profile):
        parser.error("Public release requires both Developer ID identity and notary profile")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Prepare desktop releases on an Apple Silicon Mac")
    try:
        revision = source_revision(args.version, adhoc=args.adhoc)
        destination = args.output_dir.expanduser().resolve()
        if destination.exists():
            raise ValueError(f"Output directory already exists: {destination}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        runtime = json.loads((ROOT / "macos/python-runtime.json").read_text())
        with tempfile.TemporaryDirectory(prefix=".paceman-release-", dir=destination.parent) as directory:
            staging = Path(directory) / destination.name
            staging.mkdir()
            run("bash", ROOT / "scripts/package-omarchy-release.sh", revision,
                args.version, staging)
            command = [sys.executable, str(ROOT / "scripts/package-macos-release.py"),
                       "--release-label", args.version, "--build-number", str(args.build_number),
                       "--output-dir", str(staging)]
            if args.python_archive:
                command += ["--python-archive", str(args.python_archive.expanduser().resolve())]
            if args.wheelhouse:
                command += ["--wheelhouse", str(args.wheelhouse.expanduser().resolve())]
            command += (["--adhoc"] if args.adhoc else
                        ["--identity", args.identity, "--notary-profile", args.notary_profile])
            run(*command, cwd=ROOT)
            omarchy = staging / f"Paceman-Omarchy-{args.version}.tar.gz"
            mac = staging / (f"Paceman-macos-arm64-{args.version}"
                             + ("-UNSIGNED" if args.adhoc else "") + ".dmg")
            for path in (omarchy, mac):
                if not path.is_file() or not path.with_suffix(path.suffix + ".sha256").is_file():
                    raise ValueError(f"Missing package or checksum: {path}")
                expected_hash = path.with_suffix(path.suffix + ".sha256").read_text().split()[0]
                if digest(path) != expected_hash:
                    raise ValueError(f"Checksum mismatch: {path}")
            verify_omarchy(omarchy, args.version)
            verify_mac(mac, revision, args.version, args.build_number, runtime)
            files = [artifact(omarchy, public=not args.adhoc),
                     artifact(mac, public=not args.adhoc)]
            manifest = {"schemaVersion": 1, "version": args.version,
                        "sourceRevision": revision, "buildNumber": args.build_number,
                        "mode": "local-candidate" if args.adhoc else "developer-id-notarized",
                        "pythonVersion": runtime["version"],
                        "pythonArchiveSHA256": runtime["sha256"],
                        "clientLockSHA256": digest(ROOT / "requirements-client.txt"),
                        "clientWheels": client_wheels(),
                        "xcodeVersion": output("xcodebuild", "-version"),
                        "hostMacOS": platform.mac_ver()[0], "artifacts": files}
            (staging / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            (staging / "RELEASE-NOTES.md").write_text(
                release_notes(args.version, revision, files, args.adhoc))
            checksum_files = [omarchy, mac, staging / "release-manifest.json",
                              staging / "RELEASE-NOTES.md"]
            (staging / "SHA256SUMS").write_text(
                "".join(f"{digest(path)}  {path.name}\n" for path in checksum_files))
            staging.rename(destination)
        print(f"Prepared {destination}")
        print("Local validation candidate; Mac DMG cannot be distributed." if args.adhoc
              else "Signed and notarized candidate; complete the release QA gate before upload.")
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        parser.exit(1, f"Desktop release preparation failed: {error}\n")


if __name__ == "__main__":
    main()
