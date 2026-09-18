#!/usr/bin/env bash
set -euo pipefail
source_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
preview_dir=$(mktemp -d "${TMPDIR:-/tmp}/paceman-panel.XXXXXX")
trap 'rm -rf -- "$preview_dir"' EXIT
ln -s /usr/share/omarchy/shell/Commons "$preview_dir/Commons"
ln -s /usr/share/omarchy/shell/Ui "$preview_dir/Ui"
ln -s "$source_root/desktop/plugin" "$preview_dir/plugin"
cp "$source_root/desktop/preview.qml" "$preview_dir/shell.qml"
quickshell -p "$preview_dir/shell.qml"
