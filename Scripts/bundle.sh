#!/usr/bin/env bash
# Builds VolumeControl and wraps it in build/VolumeControl.app.
# Usage: Scripts/bundle.sh [debug|release]
# Set SIGN_IDENTITY to choose a certificate. A stable certificate keeps the audio-capture
# permission across rebuilds; the ad-hoc fallback ("-") makes macOS ask again after every build.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/VolumeControl.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VolumeControl" "$APP/Contents/MacOS/VolumeControl"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/BrowserExtension" "$APP/Contents/Resources/BrowserExtension"

ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
IDENTITY="${IDENTITY:--}"

codesign --force --sign "$IDENTITY" --identifier com.hdstech.VolumeControl "$APP"
echo "Built $APP (signed with: $IDENTITY)"
