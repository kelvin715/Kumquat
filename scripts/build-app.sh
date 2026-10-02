#!/bin/bash
# Builds Kumquat.app (universal: Apple silicon + Intel) into ./build and signs it ad hoc.
#   scripts/build-app.sh            release build
#   VERSION=1.2.0 scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/Kumquat.app"

echo "▸ Compiling (release)…"
UNIVERSAL=(-c release --arch arm64 --arch x86_64)
if swift build "${UNIVERSAL[@]}" >/dev/null 2>&1; then
    BIN="$(swift build "${UNIVERSAL[@]}" --show-bin-path)/Kumquat"
else
    echo "  (universal build unavailable, building for this Mac only)"
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/Kumquat"
fi

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kumquat"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad hoc)…"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $APP ($VERSION)"
echo "  Command line: $APP/Contents/MacOS/Kumquat help"
