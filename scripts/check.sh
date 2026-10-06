#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
python=${PYTHON:-}
if [[ -z $python ]]; then
  if [[ -x .venv/bin/python ]]; then
    python=.venv/bin/python
  else
    python=python3
  fi
fi
if ! "$python" -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
  echo 'Checks require Python 3.11 or newer. Set PYTHON to a supported interpreter.' >&2
  exit 1
fi
"$python" -W error::ResourceWarning -m unittest discover -s tests -v
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
watch=firmware/esp32-watch
for check in profile sound security ancs; do
  "${CC:-cc}" -std=c11 -UNDEBUG -I "$watch/firmware/main" \
    "$watch/simulator/test_${check}.c" -o "$check_dir/test-$check"
  "$check_dir/test-$check"
done
"${CC:-cc}" -std=c11 -UNDEBUG -I "$watch/simulator/storage_stubs" -I "$watch/firmware/main" \
  "$watch/simulator/test_storage.c" "$watch/firmware/main/watch_storage.c" -o "$check_dir/test-storage"
"$check_dir/test-storage"
for helper in scripts/*.sh "$watch"/tools/*.sh "$watch"/firmware/release/flash.sh; do
  bash -n "$helper"
done
git diff --check
