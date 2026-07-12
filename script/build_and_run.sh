#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ClipFlow"
BUNDLE_ID="com.clipflow.v12"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
DERIVED_DATA="$ROOT/build/RunDerivedData"
APP="$DERIVED_DATA/Build/Products/Debug/ClipFlow.app"
BINARY="$APP/Contents/MacOS/ClipFlow"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
cd "$ROOT"
xcodegen generate
xcodebuild build \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

open_app() {
  /usr/bin/open -n "$APP"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..30}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    echo "ClipFlow did not launch within 3 seconds" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
