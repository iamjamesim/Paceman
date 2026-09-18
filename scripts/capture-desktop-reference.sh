#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
reference_dir=$(mktemp -d "${TMPDIR:-/tmp}/paceman-reference.XXXXXX")
trap 'rm -rf -- "$reference_dir"' EXIT
mkdir -p "$reference_dir/captures"
export PACEMAN_REFERENCE_DIR="$reference_dir/captures"
export PACEMAN_REFERENCE_QR="$reference_dir/example-qr.png"
# Intentionally invalid: this is not a source invitation or credential.
qrencode -o "$PACEMAN_REFERENCE_QR" -s 8 \
  '{"schema":1,"endpoint":"https://example.invalid","sourceID":"visual-reference","invitation":"not-a-real-pairing-secret","expiresAt":0}'
ln -s /usr/share/omarchy/shell/Commons "$reference_dir/Commons"
ln -s /usr/share/omarchy/shell/Ui "$reference_dir/Ui"
ln -s "$source_root/desktop/plugin" "$reference_dir/plugin"
cp "$source_root/desktop/reference.qml" "$reference_dir/shell.qml"
for reference_state in overview phone-details multiple-sessions sharing-off pairing; do
  PACEMAN_REFERENCE_STATE="$reference_state" quickshell -p "$reference_dir/shell.qml"
  test -s "$PACEMAN_REFERENCE_DIR/$reference_state.png"
done
mkdir -p "$source_root/docs/images/desktop"
cp "$reference_dir/captures/"*.png "$source_root/docs/images/desktop/"
