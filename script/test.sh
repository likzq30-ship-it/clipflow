#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

cd "$ROOT"
xcodegen generate
xcodebuild test \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT/build/TestDerivedData" \
  -only-testing:ClipFlowTests \
  -skip-testing:ClipFlowTests/RepositoryPerformanceTests \
  -skip-testing:ClipFlowTests/QuickPanelPerformanceTests \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

pkill -x ClipFlow >/dev/null 2>&1 || true

xcodebuild test \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT/build/UITestDerivedData" \
  -only-testing:ClipFlowUITests \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES

xcodebuild test \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -configuration Performance \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT/build/PerformanceDerivedData" \
  -only-testing:ClipFlowTests/RepositoryPerformanceTests \
  -only-testing:ClipFlowTests/QuickPanelPerformanceTests \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
