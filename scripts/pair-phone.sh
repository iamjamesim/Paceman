#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if [[ $# -ne 1 ]]; then
  echo 'Usage: bash scripts/pair-phone.sh https://machine.tailnet.ts.net:8443' >&2
  exit 2
fi
umask 077
python3 -m service.hub invite --endpoint "$1"
if command -v qrencode >/dev/null 2>&1; then
  qrencode -o .runtime/invitation.png -s 8 < .runtime/invitation.json
  echo 'Open .runtime/invitation.png on the computer and scan it in the phone app.'
else
  echo 'qrencode is unavailable. Paste the contents of .runtime/invitation.json into Settings → Developer tools in the app.'
fi
