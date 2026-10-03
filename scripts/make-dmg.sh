#!/bin/bash
# Packs Kumquat.app into a disk image: the app, a shortcut to Applications to drag it onto,
# and the Kumquat icon on the mounted volume.
#   scripts/make-dmg.sh                         uses build/Kumquat.app, writes build/Kumquat.dmg
#   APP=path/Kumquat.app DMG=out.dmg scripts/make-dmg.sh
#   SIGN_IDENTITY="Developer ID Application: …" scripts/make-dmg.sh   also signs the image
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-build/Kumquat.app}"
DMG="${DMG:-build/Kumquat.dmg}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VOLUME="Kumquat"

if [ ! -d "$APP" ]; then
    echo "✗ $APP not found — run scripts/build-app.sh first." >&2
    exit 1
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
cleanup() {
    hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "▸ Assembling the disk image…"
mkdir -p "$WORK/staging" "$MOUNT"
ditto "$APP" "$WORK/staging/Kumquat.app"
ln -s /Applications "$WORK/staging/Applications"
cp Resources/AppIcon.icns "$WORK/staging/.VolumeIcon.icns"

hdiutil create -quiet -ov -volname "$VOLUME" -fs HFS+ -format UDRW -srcfolder "$WORK/staging" "$WORK/rw.dmg"

# Flag the volume as having a custom icon (Finder's kHasCustomIcon bit), so it shows the Kumquat icon.
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$WORK/rw.dmg"
xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
hdiutil detach -quiet "$MOUNT"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"

if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "▸ Signing the disk image…"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
echo "✓ $DMG"
