#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Add the Paceman overlay to a clean, pinned PebbleOS checkout."""
import argparse
from pathlib import Path
import shutil
import subprocess

UPSTREAM = "a2120e2aefd3b916df7cbb141d542db9ab04916d"


def prepare(checkout: Path) -> None:
    package = Path(__file__).resolve().parents[1]
    checkout = checkout.resolve(strict=True)

    def git(*args: str) -> str:
        return subprocess.check_output(["git", "-C", str(checkout), *args], text=True).strip()

    if Path(git("rev-parse", "--show-toplevel")).resolve() != checkout:
        raise SystemExit("Pass the root of the PebbleOS checkout.")
    if git("rev-parse", "HEAD") != UPSTREAM:
        raise SystemExit(f"PebbleOS must be at {UPSTREAM}.")
    if git("status", "--porcelain"):
        raise SystemExit("Use a clean PebbleOS checkout; existing changes will not be overwritten.")
    target = checkout / "fw/services/paceman"
    if target.exists():
        raise SystemExit(f"Refusing to overwrite {target}.")
    patch = package / "pebbleos.patch"
    subprocess.run(["git", "-C", str(checkout), "apply", "--check", str(patch)], check=True)
    shutil.copytree(package / "src", target)
    esp32 = package.parent / "esp32-watch"
    shutil.copy2(esp32 / "firmware/main/watch_profile.h", target / "watch_profile.h")
    shutil.copy2(esp32 / "UPSTREAM_LICENSE", target / "watch_profile.LICENSE")
    shutil.copytree(package / "resources", checkout / "resources/normal/base/ttf/paceman")
    subprocess.run(["git", "-C", str(checkout), "apply", str(patch)], check=True)
    print(f"Prepared {checkout} at {UPSTREAM}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    prepare(parser.parse_args().checkout)
