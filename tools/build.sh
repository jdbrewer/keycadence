#!/bin/zsh
# Local signed build, without changing the machine's active Xcode.
# Usage: tools/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcodegen generate --quiet
xcodebuild -project Keycadence.xcodeproj -scheme Keycadence -configuration "${1:-Release}" \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER="" \
  build 2>&1 | grep -E "error:|warning: |BUILD (SUCCEEDED|FAILED)" | grep -v "Metadata extraction" | sort -u
