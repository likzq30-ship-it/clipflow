#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

cd "$ROOT"
xcodegen generate
xcodebuild clean build \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$ROOT/build/ReleaseDerivedData" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

BINARY="$ROOT/build/ReleaseDerivedData/Build/Products/Release/ClipFlow.app/Contents/MacOS/ClipFlow"
lipo "$BINARY" -verify_arch arm64 x86_64
file "$BINARY"
