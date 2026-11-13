#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Core
xcodegen generate
xcodebuild -project benSync.xcodeproj -scheme benSync -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
