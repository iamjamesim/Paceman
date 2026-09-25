#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
font=${1:-/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf}
bold_font=${2:-/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf}
output_dir=firmware/main/fonts

if [[ ! -f $font ]]; then
  echo "JetBrains Mono font not found: $font" >&2
  exit 1
fi

if [[ ! -f $bold_font ]]; then
  echo "JetBrains Mono bold font not found: $bold_font" >&2
  exit 1
fi

font=$(realpath -- "$font")
bold_font=$(realpath -- "$bold_font")
cd "$project_dir"
mkdir -p "$output_dir"

common=(
  --yes lv_font_conv@1.5.3
  --font "$font"
  --format lvgl
  --bpp 4
  --no-compress
  --no-prefilter
  --force-fast-kern-format
  --lv-include lvgl.h
)

npx --yes lv_font_conv@1.5.3 --font "$bold_font" --format lvgl \
  --bpp 4 --no-compress --no-prefilter --force-fast-kern-format \
  --lv-include lvgl.h --size 27 \
  --range 0x20,0x30-0x39,0x41-0x5A,0x61-0x7A,0xF041 \
  --output "$output_dir/jetbrains_mono_27.c"

npx "${common[@]}" --size 14 \
  --range 0xF0E7 \
  --output "$output_dir/jetbrains_mono_14_battery.c"

npx "${common[@]}" --size 22 \
  --range 0x20,0x25,0x2D,0x30-0x39,0x41-0x5A,0x64,0x68,0x6D,0xB0,0xF1DA \
  --output "$output_dir/jetbrains_mono_22.c"

npx "${common[@]}" --size 26 \
  --range 0xF0338 \
  --output "$output_dir/jetbrains_mono_26_connection.c"

npx "${common[@]}" --size 30 \
  --range 0xF0079-0xF0082,0xF0091 \
  --output "$output_dir/jetbrains_mono_30_battery.c"

npx "${common[@]}" --size 42 \
  --range 0x20,0x2D,0x30-0x39,0xB0 \
  --output "$output_dir/jetbrains_mono_42.c"

npx "${common[@]}" --size 48 \
  --range 0xE302,0xE308,0xE30D,0xE313,0xE318,0xE31A,0xE31D,0xE32B,0xE32E,0xE333,0xE33D,0xE346 \
  --output "$output_dir/jetbrains_mono_48_icons.c"

npx "${common[@]}" --size 114 \
  --range 0x2D,0x30-0x3A \
  --output "$output_dir/jetbrains_mono_114.c"

# lv_font_conv adds an extra blank line after the final preprocessor guard.
# Normalize it so regeneration remains clean under `git diff --check`.
python3 - "$output_dir" <<'NORMALIZE'
from pathlib import Path
import sys
for path in Path(sys.argv[1]).glob("*.c"):
    path.write_text(path.read_text().rstrip() + "\n")
NORMALIZE

echo "Generated firmware fonts in $output_dir"
