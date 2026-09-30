#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
firmware_dir=$repo_dir/firmware
output_dir=${1:-$repo_dir/dist}
version=$(sed -nE 's/set\(PROJECT_VER "([^"]+)"\)/\1/p' "$firmware_dir/CMakeLists.txt")
identity_version=$(sed -nE \
  's/.*OMARCHY_FIRMWARE_VERSION_(MAJOR|MINOR|PATCH) = ([0-9]+),/\2/p' \
  "$firmware_dir/main/watch_profile.h" | paste -s -d . -)
package_name=paceman-watch-v${version}-flash
package_dir=$output_dir/$package_name
archive=$output_dir/$package_name.tar.gz

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

command -v idf.py >/dev/null || {
  echo "Activate ESP-IDF 5.5.x before packaging the release." >&2
  exit 1
}

if [[ $version != "$identity_version" ]]; then
  echo "Project version $version does not match firmware identity version $identity_version." >&2
  exit 1
fi

if [[ -e $package_dir || -e $archive ]]; then
  echo "Release output already exists: $package_name" >&2
  exit 1
fi

(cd "$firmware_dir" && idf.py build)

mkdir -p "$package_dir"
install -m 0644 "$firmware_dir/build/bootloader/bootloader.bin" "$package_dir/bootloader.bin"
install -m 0644 "$firmware_dir/build/partition_table/partition-table.bin" "$package_dir/partition-table.bin"
install -m 0644 "$firmware_dir/build/omarchy_watch.bin" "$package_dir/paceman_watch.bin"
install -m 0755 "$firmware_dir/release/flash.sh" "$package_dir/flash.sh"
sed "s/@VERSION@/$version/g" "$firmware_dir/release/README.txt" >"$package_dir/README.txt"
for notice in LICENSE THIRD_PARTY_NOTICES.md UPSTREAM.md; do
  install -m 0644 "$repo_dir/$notice" "$package_dir/$notice"
done

(cd "$package_dir" && checksum bootloader.bin partition-table.bin paceman_watch.bin flash.sh README.txt LICENSE THIRD_PARTY_NOTICES.md UPSTREAM.md >SHA256SUMS)
(cd "$output_dir" && tar -czf "$archive" "$package_name")
(cd "$output_dir" && checksum "$package_name.tar.gz" >"$package_name.tar.gz.sha256")

echo "Created $archive"
cat "$archive.sha256"
