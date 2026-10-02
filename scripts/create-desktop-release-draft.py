#!/usr/bin/env python3
"""Compatibility entry point for staging and verifying a desktop draft release."""
import argparse
from pathlib import Path
import subprocess

from desktop_release import stage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release_dir", type=Path)
    args = parser.parse_args()
    try:
        stage(args.release_dir.expanduser().resolve(strict=True))
    except (OSError, KeyError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Desktop draft upload refused: {error}\n")


if __name__ == "__main__":
    main()
