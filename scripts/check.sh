#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
python3 -W error::ResourceWarning -m unittest discover -s tests -v
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
watch=firmware/esp32-watch
for check in profile sound; do
  "${CC:-cc}" -std=c11 -UNDEBUG -I "$watch/firmware/main" \
    "$watch/simulator/test_${check}.c" -o "$check_dir/test-$check"
  "$check_dir/test-$check"
done
for helper in scripts/*.sh "$watch"/tools/*.sh "$watch"/firmware/release/flash.sh; do
  bash -n "$helper"
done
git diff --check
