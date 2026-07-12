#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
VERSION="2.0.0"
PRODUCTS="$ROOT/build/ReleaseDerivedData/Build/Products/Release"
SOURCE_APP="$PRODUCTS/ClipFlow.app"
mkdir -p "$ROOT/build" "$ROOT/dist/release"
WORK_ROOT="$(mktemp -d "$ROOT/build/clipflow-package.XXXXXX")"
STAGE="$WORK_ROOT/ClipFlow-$VERSION"
APP="$STAGE/ClipFlow.app"
MOUNT_POINT="$WORK_ROOT/mount"
DMG="$ROOT/dist/release/ClipFlow-$VERSION-universal.dmg"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT INT TERM

"$ROOT/script/build_release.sh"
rm -f "$DMG"
mkdir -p "$STAGE" "$MOUNT_POINT" "$(dirname "$DMG")"
ditto "$SOURCE_APP" "$APP"
ln -s /Applications "$STAGE/Applications"

SIGNED_WITH_DEVELOPER_ID=0
NOTARIZED=0
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$APP"
  SIGNED_WITH_DEVELOPER_ID=1
else
  codesign --force --options runtime --timestamp=none --sign - "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E 'flags=.*runtime' >/dev/null

hdiutil create \
  -volname "ClipFlow $VERSION" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG"

if [[ "$SIGNED_WITH_DEVELOPER_ID" -eq 1 ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
fi

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  if [[ "$SIGNED_WITH_DEVELOPER_ID" -ne 1 ]]; then
    echo "NOTARYTOOL_PROFILE requires DEVELOPER_ID_APPLICATION" >&2
    exit 2
  fi
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  NOTARIZED=1
fi

hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED=1
test -d "$MOUNT_POINT/ClipFlow.app"
test -L "$MOUNT_POINT/Applications"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/ClipFlow.app"
lipo "$MOUNT_POINT/ClipFlow.app/Contents/MacOS/ClipFlow" \
  -verify_arch arm64 x86_64

if [[ "$NOTARIZED" -eq 1 ]]; then
  spctl --assess --type execute --verbose=4 "$MOUNT_POINT/ClipFlow.app"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
  echo "DEVELOPER ID BUILD — NOTARIZED AND STAPLED"
elif [[ "$SIGNED_WITH_DEVELOPER_ID" -eq 1 ]]; then
  echo "DEVELOPER ID BUILD — NOT NOTARIZED"
else
  echo "LOCAL TEST BUILD — AD-HOC SIGNED, NOT NOTARIZED"
fi

hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0
shasum -a 256 "$DMG"
