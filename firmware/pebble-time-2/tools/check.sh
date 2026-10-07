#!/usr/bin/env bash
set -euo pipefail
package=$(cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -UNDEBUG \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$package/src" -I "$package/../esp32-watch/firmware/main" \
  "$package/src/paceman_state.c" "$package/tests/test_state.c" -o "$build/test-state"
"$build/test-state"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter -UNDEBUG -DCONFIG_SPEAKER=1 \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$package/tests/stubs" -I "$package/src" \
  -I "$package/../esp32-watch/firmware/main" \
  "$package/tests/test_adapter.c" "$package/src/paceman_storage.c" \
  "$package/src/paceman_state.c" -lz -o "$build/test-adapter"
"$build/test-adapter"
