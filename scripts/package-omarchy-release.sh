#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 GIT_REF VERSION OUTPUT_DIRECTORY" >&2
  exit 2
fi

ref=$1
version=$2
output_dir=$3

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "Version must look like 0.1.0 or 0.1.0-rc1" >&2
  exit 2
fi

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
git -C "$repo" rev-parse --verify "${ref}^{commit}" >/dev/null
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
archive="$output_dir/Paceman-Omarchy-$version.tar.gz"
checksum="$archive.sha256"
if [[ -e $archive || -e $checksum ]]; then
  echo "Release output already exists for $version" >&2
  exit 1
fi
temporary=$(mktemp "$output_dir/.Paceman-Omarchy-$version.XXXXXX")
trap 'rm -f "$temporary"' EXIT

git -C "$repo" archive --format=tar \
  --prefix="Paceman-Omarchy-$version/" "$ref" -- \
  README.md LICENSE THIRD_PARTY_NOTICES.md docs omarchy service systemd \
  requirements-push.txt scripts/install-omarchy.sh scripts/uninstall-omarchy.sh \
  | gzip -n > "$temporary"
mv "$temporary" "$archive"

(
  cd "$output_dir"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$checksum")"
)
printf 'Created %s\n' "$archive"
