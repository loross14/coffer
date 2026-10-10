#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${PLANISPHERE_OUTPUT_DIR:-$REPO_ROOT/dist}"
APP_PATH="$OUTPUT_DIR/Planisphere.app"
MODULE_CACHE="$REPO_ROOT/.build/ModuleCache"
mkdir -p "$OUTPUT_DIR" "$MODULE_CACHE"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build --disable-sandbox -c "$CONFIGURATION" --product Planisphere
BINARY_DIR="$(swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGING_APP="$STAGING_DIR/Planisphere.app"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$BINARY_DIR/Planisphere" "$STAGING_APP/Contents/MacOS/Planisphere"
cp Resources/Info.plist "$STAGING_APP/Contents/Info.plist"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" xcrun swift scripts/make-icon.swift "$STAGING_DIR/AppIcon.iconset"
iconutil -c icns "$STAGING_DIR/AppIcon.iconset" -o "$STAGING_APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signing is for a locally runnable build. For external distribution provide a Developer ID identity and notarize.
SIGNING_IDENTITY="${PLANISPHERE_SIGN_IDENTITY:--}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - --options runtime --timestamp=none "$STAGING_APP"
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$STAGING_APP"
fi
codesign --verify --deep --strict "$STAGING_APP"
if [ -e "$APP_PATH" ]; then
    BACKUP_PATH="$OUTPUT_DIR/Planisphere.previous.$(date +%s).app"
    mv "$APP_PATH" "$BACKUP_PATH"
fi
mv "$STAGING_APP" "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/Planisphere-0.1.0-mac.zip"
shasum -a 256 "$OUTPUT_DIR/Planisphere-0.1.0-mac.zip" > "$OUTPUT_DIR/Planisphere-0.1.0-mac.zip.sha256"
printf 'Built %s\n' "$APP_PATH"
