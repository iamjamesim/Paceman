#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$project_dir/simulator/build"
output_dir="$project_dir/simulator/output"
lvgl_dir="$project_dir/firmware/managed_components/lvgl__lvgl"

for dependency in cmake ninja magick; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Missing preview dependency: $dependency" >&2
    exit 1
  fi
done

if [[ ! -f "$lvgl_dir/CMakeLists.txt" ]]; then
  cat >&2 <<EOF
LVGL has not been downloaded yet. Configure the firmware first:

  cd "$project_dir/firmware"
  idf.py reconfigure
EOF
  exit 1
fi

cmake -S "$project_dir/simulator" -B "$build_dir" -G Ninja
cmake --build "$build_dir" --parallel 2
mkdir -p "$output_dir"
ppm_path=$(mktemp "$output_dir/watchface.XXXXXX.ppm")
trap 'rm -f "$ppm_path"' EXIT
"$build_dir/render-watchface" "$ppm_path"

magick "$ppm_path" "$output_dir/watchface.png"
corner_radius=$("$build_dir/render-watchface" --corner-radius)
magick "$output_dir/watchface.png" \
    \( +clone -alpha extract -fill black -colorize 100 \
       -fill white -draw "roundrectangle 0,0,409,501,$corner_radius,$corner_radius" \) \
    -alpha off -compose CopyOpacity -composite \
    "$output_dir/watchface-rounded.png"

echo "$output_dir/watchface-rounded.png"
