#!/usr/bin/env python3
"""Build a self-contained Apple Silicon Mac DMG from this checkout.

Production requires a clean, exact-tag checkout, Developer ID Application
identity, and a notarytool keychain profile. --adhoc is a local dry run only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.request import urlopen

from notarize_release import notarize

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
RUNTIME_LOCK = ROOT / "macos/python-runtime.json"
CLIENT_LOCK = ROOT / "requirements-client.txt"
MINIMUM_MACOS = "15.0"
MAX_DMG_BYTES = 50_000_000
MACHO_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def run(*args: str | Path, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def checkout_revision(label: str, *, adhoc: bool) -> str:
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if not adhoc:
        if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).strip():
            raise ValueError("Production packages require a clean checkout")
        tag = f"refs/tags/desktop-v{label}"
        if (subprocess.check_output(["git", "cat-file", "-t", tag], cwd=ROOT, text=True).strip() != "tag"
                or subprocess.check_output(["git", "rev-parse", f"{tag}^{{commit}}"],
                                           cwd=ROOT, text=True).strip() != revision):
            raise ValueError(f"Production checkout must match annotated tag desktop-v{label}")
    return revision


def verify_developer_id(identity: str):
    known = subprocess.check_output(["/usr/bin/security", "find-identity", "-v", "-p",
                                     "codesigning"], text=True)
    if not any(identity in line and "Developer ID Application" in line
               and "(ZTG42P5438)" in line for line in known.splitlines()):
        raise ValueError("Signing identity must be a Developer ID Application certificate "
                         "for team ZTG42P5438")


def runtime_archive(archive: Path | None, scratch: Path) -> tuple[Path, dict]:
    lock = json.loads(RUNTIME_LOCK.read_text())
    if lock["architecture"] != "aarch64-apple-darwin" or lock["flavor"] != "install_only":
        raise ValueError("The Mac runtime lock must name an arm64 install_only build")
    if archive is None:
        archive = scratch / "python.tar.gz"
        with urlopen(lock["url"], timeout=60) as source, archive.open("wb") as target:
            shutil.copyfileobj(source, target)
    if sha256(archive) != lock["sha256"]:
        raise ValueError("Bundled Python archive does not match macos/python-runtime.json")
    return archive, lock


def copy_runtime(archive: Path, app: Path, scratch: Path) -> Path:
    extracted = scratch / "extracted"
    extracted.mkdir()
    run("/usr/bin/tar", "-xzf", archive, "-C", extracted)
    runtime = extracted / "python"
    if not (runtime / "bin/python3").is_file():
        raise ValueError("Runtime archive has no python/bin/python3")
    destination = app / "Contents/Resources/python"
    shutil.move(str(runtime), destination)
    return destination / "bin/python3"


def install_client_packages(python: Path, wheelhouse: Path | None, scratch: Path):
    if wheelhouse is None:
        wheelhouse = scratch / "wheels"
        wheelhouse.mkdir()
        run(python, "-m", "pip", "download", "--require-hashes", "--only-binary=:all:",
            "--dest", wheelhouse, "-r", CLIENT_LOCK)
    site = python.parent.parent / "lib/python3.14/site-packages"
    run(python, "-m", "pip", "install", "--no-index", "--find-links", wheelhouse,
        "--require-hashes", "--no-compile", "--target", site, "-r", CLIENT_LOCK)
    # pip is needed to assemble the package, not to run Paceman. Keep the
    # customer bundle smaller and avoid shipping an unused package manager.
    shutil.rmtree(site / "pip")
    for metadata in site.glob("pip-*.dist-info"):
        shutil.rmtree(metadata)
    for name in ("pip", "pip3", "pip3.14"):
        (python.parent / name).unlink(missing_ok=True)


def copy_source(app: Path, revision: str, runtime: dict, label: str):
    library = app / "Contents/Resources/lib"
    library.mkdir(parents=True)
    for folder in ("macos", "service"):
        shutil.copytree(ROOT / folder, library / folder,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.png"))
    shutil.copy2(CLIENT_LOCK, library / CLIENT_LOCK.name)
    notices = app / "Contents/Resources/Notices"
    notices.mkdir()
    shutil.copy2(ROOT / "LICENSE", notices / "Paceman-LICENSE")
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", notices / "Paceman-third-party.md")
    shutil.copytree(ROOT / "macos/runtime-notices/python", notices / "python")
    metadata = json.loads((notices / "python/PYTHON.json").read_text())
    if metadata.get("python_version") != runtime["version"]:
        raise ValueError("Bundled Python notices do not match the locked runtime version")

    def license_paths(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key == "license_paths" and isinstance(item, list):
                    yield from item
                else:
                    yield from license_paths(item)
        elif isinstance(value, list):
            for item in value:
                yield from license_paths(item)

    for path in set(license_paths(metadata)):
        valid_path = (isinstance(path, str) and path.startswith("licenses/")
                      and ".." not in Path(path).parts)
        if not valid_path or not (notices / "python" / path).is_file():
            raise ValueError(f"Bundled Python notice is missing: {path}")
    (library / "build-info.json").write_text(json.dumps({
        "release": label, "sourceRevision": revision,
        "pythonVersion": runtime["version"], "pythonArchiveSHA256": runtime["sha256"],
        "minimumMacOS": MINIMUM_MACOS, "architecture": "arm64",
    }, indent=2) + "\n")


def smoke(app: Path, version: str):
    python = app / "Contents/Resources/python/bin/python3"
    library = app / "Contents/Resources/lib"
    env = {**os.environ, "PYTHONPATH": str(library), "PYTHONDONTWRITEBYTECODE": "1"}
    script = ("import sys, importlib.util, httpx, service.hub, service.push, macos.install; "
              f"assert sys.version.startswith({version!r}); "
              "assert httpx.__version__ == '0.28.1'; "
              "assert importlib.util.find_spec('pip') is None")
    run(python, "-c", script, cwd=library, env=env)


def sign_app(app: Path, identity: str, *, adhoc: bool):
    options = ["--force", "--sign", identity, "--options", "runtime"]
    if not adhoc:
        options.append("--timestamp")
    runtime = app / "Contents/Resources/python"
    binaries = []
    for path in runtime.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as source:
                if source.read(4) in MACHO_MAGIC:
                    binaries.append(path)
    for binary in sorted(binaries, key=lambda path: len(path.parts), reverse=True):
        run("/usr/bin/codesign", *options, binary, stdout=subprocess.DEVNULL)
    run("/usr/bin/codesign", *options, app / "Contents/MacOS/PacemanBackground")
    run("/usr/bin/codesign", *options, app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


def make_dmg(app: Path, output: Path, scratch: Path):
    contents = scratch / "dmg-contents"
    contents.mkdir()
    shutil.copytree(app, contents / "Paceman.app", symlinks=True)
    run("/usr/bin/hdiutil", "create", "-quiet", "-volname", "Paceman", "-srcfolder",
        contents, "-format", "UDZO", "-imagekey", "zlib-level=9", "-o", output)
    if output.stat().st_size > MAX_DMG_BYTES:
        raise ValueError(f"DMG is over the {MAX_DMG_BYTES // 1_000_000} MB download budget")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-label", required=True, help="Example: 0.1.0-alpha.1")
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--python-archive", type=Path, help="Use a cached copy of the pinned runtime")
    parser.add_argument("--wheelhouse", type=Path, help="Use predownloaded wheels offline")
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--adhoc", action="store_true", help="Local dry run; never distribute")
    signing.add_argument("--identity", help="Developer ID Application identity for public release")
    parser.add_argument("--notary-profile", help="notarytool keychain profile; required for public release")
    parser.add_argument("--resume", action="store_true", help="Resume the saved Apple submission without rebuilding")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-alpha\.\d+|-beta\.\d+)?", args.release_label):
        parser.error("Release label must be a numeric version with optional alpha or beta suffix")
    if args.build_number < 1:
        parser.error("Build number must be positive")
    if bool(args.identity) != bool(args.notary_profile):
        parser.error("Production builds require both Developer ID identity and notary profile")
    if args.resume and args.adhoc:
        parser.error("Only a saved production notarization can be resumed")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Mac release packages must be built on an Apple Silicon Mac")
    marketing_version = args.release_label.split("-")[0]
    try:
        if args.identity:
            verify_developer_id(args.identity)
        revision = checkout_revision(args.release_label, adhoc=args.adhoc)
        args.output_dir.mkdir(parents=True, exist_ok=True)
        suffix = "-UNSIGNED" if args.adhoc else ""
        dmg = args.output_dir / f"Paceman-macos-arm64-{args.release_label}{suffix}.dmg"
        if not args.resume and dmg.exists():
            raise ValueError("Output already exists; use --resume for a saved Apple submission")
        if not args.resume:
            with tempfile.TemporaryDirectory(prefix="paceman-mac-release-") as temporary:
                scratch = Path(temporary)
                os.environ["CLANG_MODULE_CACHE_PATH"] = str(scratch / "clang-cache")
                os.environ["SWIFT_MODULE_CACHE_PATH"] = str(scratch / "swift-cache")
                archive, runtime = runtime_archive(args.python_archive, scratch)
                from macos.install import build_app
                app = scratch / "Paceman.app"
                build_app(app, version=marketing_version, build_number=str(args.build_number),
                          minimum_macos=MINIMUM_MACOS, sign=False)
                python = copy_runtime(archive, app, scratch)
                install_client_packages(python, args.wheelhouse, scratch)
                copy_source(app, revision, runtime, args.release_label)
                smoke(app, runtime["version"])
                sign_app(app, args.identity or "-", adhoc=args.adhoc)
                smoke(app, runtime["version"])
                make_dmg(app, dmg, scratch)
                if args.identity:
                    run("/usr/bin/codesign", "--force", "--sign", args.identity, "--timestamp", dmg)
        if args.notary_profile:
            notarize(dmg, args.notary_profile, {
                "sourceRevision": revision, "version": args.release_label,
                "buildNumber": args.build_number, "identity": args.identity,
            }, resume=args.resume)
        digest = sha256(dmg)
        (dmg.with_suffix(dmg.suffix + ".sha256")).write_text(f"{digest}  {dmg.name}\n")
        print(f"Built {dmg} ({dmg.stat().st_size / 1_000_000:.1f} MB)")
        print(f"SHA-256 {digest}")
        if args.adhoc:
            print("Local dry run only: ad hoc signature, no Developer ID or notarization.")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Mac release build failed: {error}\n")


if __name__ == "__main__":
    main()
