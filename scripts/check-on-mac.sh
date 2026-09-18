#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Run this check on the Mac with Xcode.' >&2
  exit 1
fi
xcodebuild -version
xcodebuild -project ios/AgentCompanion.xcodeproj -scheme AgentCompanion \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .runtime/DerivedData CODE_SIGNING_ALLOWED=NO build
echo 'Simulator build complete. Run Product > Test in Xcode, then install on the real iPhone.'
