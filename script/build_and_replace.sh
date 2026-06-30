#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipFlow"
INSTALLED_APP="/Applications/ClipFlow-v12.app"
BACKUP_DIR="$ROOT/dist/backups"
DERIVED_DATA="$ROOT/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"

cd "$ROOT"

if [[ ! -d "$INSTALLED_APP" ]]; then
  echo "Missing installed app: $INSTALLED_APP" >&2
  exit 1
fi

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

xcodebuild \
  -project ClipFlow.xcodeproj \
  -scheme ClipFlow \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Build did not produce $BUILT_APP" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/ClipFlow-v12.$(date +%Y%m%d-%H%M%S).app"
ditto "$INSTALLED_APP" "$backup"

pkill -x ClipFlow 2>/dev/null || true
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
codesign --force --deep --sign - "$INSTALLED_APP"
open "$INSTALLED_APP"

echo "Replaced $INSTALLED_APP"
echo "Backup: $backup"
