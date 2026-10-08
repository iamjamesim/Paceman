#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/python3 -I "$(dirname -- "$0")/../omarchy/install.py" uninstall "$@"
