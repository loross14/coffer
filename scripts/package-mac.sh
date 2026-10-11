#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${PLANISPHERE_OUTPUT_DIR:-$REPO_ROOT/dist}"
APP_PATH="$OUTPUT_DIR/Planisphere.app"
MODULE_CACHE="$REPO_ROOT/.build/ModuleCache"
PYTHON_ARCHIVE="${PLANISPHERE_PYTHON_ARCHIVE:-$REPO_ROOT/.build/python-runtime.tar.gz}"
PYTHON_WHEELS="${PLANISPHERE_PYTHON_WHEELS:-$REPO_ROOT/.build/python-wheels}"
if [ ! -f "$PYTHON_ARCHIVE" ]; then
    printf 'Missing pinned Python runtime archive. Download the URL listed by scripts/bundle-python.py and set PLANISPHERE_PYTHON_ARCHIVE.\n' >&2
    exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
    printf 'This package currently supports Apple Silicon only.\n' >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR" "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
swift build --disable-sandbox -c "$CONFIGURATION" --product Planisphere
BINARY_DIR="$(swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGING_APP="$STAGING_DIR/Planisphere.app"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$BINARY_DIR/Planisphere" "$STAGING_APP/Contents/MacOS/Planisphere"
cp Resources/Info.plist "$STAGING_APP/Contents/Info.plist"
ditto Resources/ThirdPartyNotices "$STAGING_APP/Contents/Resources/ThirdPartyNotices"
mkdir -p "$STAGING_APP/Contents/Resources/Grapheine"
cp Integrations/Grapheine/bridge.py "$STAGING_APP/Contents/Resources/Grapheine/bridge.py"
cp Integrations/Grapheine/local_guard.py "$STAGING_APP/Contents/Resources/Grapheine/local_guard.py"
cp Integrations/Grapheine/local_plan.py "$STAGING_APP/Contents/Resources/Grapheine/local_plan.py"
cp Integrations/Grapheine/graph_adapter.py "$STAGING_APP/Contents/Resources/Grapheine/graph_adapter.py"
/usr/bin/python3 scripts/check-reader.py
cp Integrations/Grapheine/planisphere_reader.py "$STAGING_APP/Contents/Resources/Grapheine/planisphere_reader.py"
cp Integrations/Grapheine/reader-provenance.json "$STAGING_APP/Contents/Resources/Grapheine/reader-provenance.json"
/usr/bin/python3 scripts/bundle-grapheine.py "${PLANISPHERE_GRAPHEINE_SOURCE:-$REPO_ROOT/../Grapheine}" "$STAGING_APP/Contents/Resources/Grapheine/engine"
/usr/bin/python3 scripts/bundle-python.py "$PYTHON_ARCHIVE" "$STAGING_APP/Contents/Frameworks/Python.framework" "$PYTHON_WHEELS"
SPARKLE_FRAMEWORK="$REPO_ROOT/.build/artifacts/mac/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK" "$STAGING_APP/Contents/Frameworks/Sparkle.framework"
if [ -n "${PLANISPHERE_UPDATE_PUBLIC_KEY:-}" ]; then
    /usr/bin/python3 - "$STAGING_APP/Contents/Info.plist" "$PLANISPHERE_UPDATE_PUBLIC_KEY" <<'PY'
import base64, plistlib, sys
from pathlib import Path
path, key = Path(sys.argv[1]), sys.argv[2]
if len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit("The update public key must contain 32 bytes.")
info = plistlib.loads(path.read_bytes())
info.update(SUFeedURL="https://www.planisphere.ooo/mac/appcast.xml", SUPublicEDKey=key,
            SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
path.write_bytes(plistlib.dumps(info))
PY
fi
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" xcrun swift scripts/make-icon.swift "$STAGING_DIR/AppIcon.iconset"
iconutil -c icns "$STAGING_DIR/AppIcon.iconset" -o "$STAGING_APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signing is for a locally runnable build. For external distribution provide a Developer ID identity and notarize.
SIGNING_IDENTITY="${PLANISPHERE_SIGN_IDENTITY:--}"
/usr/bin/python3 scripts/sign-bundle.py "$STAGING_APP" "$SIGNING_IDENTITY"
if [ -e "$APP_PATH" ]; then
    BACKUP_PATH="$OUTPUT_DIR/Planisphere.previous.$(date +%s).app"
    mv "$APP_PATH" "$BACKUP_PATH"
fi
mv "$STAGING_APP" "$APP_PATH"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/Planisphere-$VERSION-mac.zip"
shasum -a 256 "$OUTPUT_DIR/Planisphere-$VERSION-mac.zip" > "$OUTPUT_DIR/Planisphere-$VERSION-mac.zip.sha256"
printf 'Built %s\n' "$APP_PATH"
