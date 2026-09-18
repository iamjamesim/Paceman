#!/usr/bin/env bash

set -euo pipefail

if (($# != 1)); then
  echo "usage: ./flash.sh /dev/ttyACM0" >&2
  exit 2
fi

port=$1
release_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if command -v esptool >/dev/null; then
  esptool_command=(esptool)
elif command -v esptool.py >/dev/null; then
  esptool_command=(esptool.py)
elif python3 -c 'import esptool' >/dev/null 2>&1; then
  esptool_command=(python3 -m esptool)
else
  echo "Espressif esptool 4.x or 5.x is required." >&2
  echo "See https://docs.espressif.com/projects/esptool/en/latest/esp32s3/" >&2
  exit 1
fi

version_output=$("${esptool_command[@]}" version 2>&1 || true)
version_major=$(sed -nE 's/^[^0-9]*([0-9]+)\..*/\1/p' <<<"$version_output" | head -n 1)

if [[ $version_major =~ ^[0-9]+$ ]] && ((version_major >= 5)); then
  "${esptool_command[@]}" \
    --chip esp32s3 \
    --port "$port" \
    --baud 460800 \
    --before default-reset \
    --after hard-reset \
    write-flash \
    --flash-mode dio \
    --flash-size 32MB \
    --flash-freq 80m \
    0x0 "$release_dir/bootloader.bin" \
    0x8000 "$release_dir/partition-table.bin" \
    0x10000 "$release_dir/omarchy_watch.bin"
else
  "${esptool_command[@]}" \
    --chip esp32s3 \
    --port "$port" \
    --baud 460800 \
    --before default_reset \
    --after hard_reset \
    write_flash \
    --flash_mode dio \
    --flash_size 32MB \
    --flash_freq 80m \
    0x0 "$release_dir/bootloader.bin" \
    0x8000 "$release_dir/partition-table.bin" \
    0x10000 "$release_dir/omarchy_watch.bin"
fi
