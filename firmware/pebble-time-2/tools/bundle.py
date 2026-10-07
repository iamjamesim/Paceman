#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Combine verified slot 0/1 builds into the Pebble app's sideload format."""
import argparse
import importlib.util
import json
from pathlib import Path
import zipfile


def bundle(checkout: Path, inputs: list[Path], output: Path) -> None:
    spec = importlib.util.spec_from_file_location("pebble_crc", checkout / "tools/stm32_crc.py")
    crc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(crc)
    slots = {}
    identity = None
    for path in inputs:
        if path.resolve() == output.resolve():
            raise ValueError("Output cannot replace an input bundle.")
        with zipfile.ZipFile(path) as source:
            manifest = json.loads(source.read("manifest.json"))
            firmware = manifest["firmware"]
            slot = firmware["slot"]
            if firmware["type"] != "normal" or slot not in (0, 1) or slot in slots:
                raise ValueError("Provide one normal build for each slot.")
            current = tuple(firmware[key] for key in ("hwrev", "commit", "versionTag"))
            if firmware["hwrev"] not in ("obelix_dvt", "obelix_pvt") or (identity and current != identity):
                raise ValueError("Both builds must have the same Obelix revision and source version.")
            identity = current
            files = {}
            for name in source.namelist():
                if Path(name).name != name:
                    raise ValueError("Input must be a single-slot bundle.")
                files[name] = source.read(name)
            for key in ("firmware", "resources"):
                item = manifest[key]
                data = files[item["name"]]
                if len(data) != item["size"] or crc.crc32(data) != item["crc"]:
                    raise ValueError(f"Invalid {key} size/CRC in {path.name}.")
            slots[slot] = files
    if set(slots) != {0, 1}:
        raise ValueError("Both firmware slots are required.")
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as target:
        for slot in (0, 1):
            for name, data in slots[slot].items():
                target.writestr(f"slot{slot}/{name}", data)
        package = Path(__file__).resolve().parents[1]
        target.write(package / "resources/LICENSE.Roboto.txt", "PACEMAN-LICENSES/Roboto.txt")
        target.write(package.parent / "esp32-watch/UPSTREAM_LICENSE", "PACEMAN-LICENSES/watch_profile.txt")
    print(f"Built {output} for {identity[0]}, both slots.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pebbleos", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("slots", nargs=2, type=Path)
    args = parser.parse_args()
    bundle(args.pebbleos, args.slots, args.output)
