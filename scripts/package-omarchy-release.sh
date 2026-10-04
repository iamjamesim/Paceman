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
verification=$(mktemp -d "$output_dir/.Paceman-verify-$version.XXXXXX")
trap 'rm -f "$temporary"; rm -rf "$verification"' EXIT

git -C "$repo" archive --format=tar \
  --prefix="Paceman-Omarchy-$version/" "$ref" -- \
  README.md LICENSE THIRD_PARTY_NOTICES.md docs omarchy service systemd \
  requirements-client.txt requirements-push.txt scripts/install-omarchy.sh scripts/uninstall-omarchy.sh \
  | gzip -n > "$temporary"

if [[ $(uname -s) == Linux ]]; then
  if ! command -v systemd-analyze >/dev/null; then
    echo "systemd-analyze is required to validate Omarchy release units on Linux" >&2
    exit 1
  fi
  python3 - "$temporary" "$version" "$verification" <<'PY'
from pathlib import Path
import sys
import tarfile

archive, version, destination = sys.argv[1:]
destination = Path(destination)
app = destination / "app"
state = destination / "state"
app.mkdir()
python = state / "push-venv/bin/python3"
python.parent.mkdir(parents=True)
python.symlink_to(sys.executable)
with tarfile.open(archive, "r:gz") as source:
    for name in ("paceman-source.service", "paceman-push.service"):
        member = f"Paceman-Omarchy-{version}/systemd/{name}"
        template = source.extractfile(member).read().decode()
        (destination / name).write_text(template.replace("@APP@", str(app))
                                        .replace("@STATE@", str(state)))
PY
  systemd-analyze verify "$verification/paceman-source.service" "$verification/paceman-push.service"
else
  echo "Skipping systemd validation on this platform; Linux CI validates the packaged units."
fi
mv "$temporary" "$archive"

(
  cd "$output_dir"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$checksum")"
)
printf 'Created %s\n' "$archive"
