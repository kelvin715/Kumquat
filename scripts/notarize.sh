#!/bin/bash
# Builds Kumquat.app, signs it with your Developer ID, notarizes it with Apple and staples the
# ticket, then does the same for the disk image, so people can open the download directly.
# Produces build/Kumquat.dmg and build/Kumquat.zip.
#
# One-time setup (needs an Apple Developer Program membership):
#   1. Xcode › Settings › Accounts › your team › Manage Certificates › + › Developer ID Application
#   2. Store notary credentials in your keychain (you'll be asked for an app-specific password,
#      created at appleid.apple.com › Sign-In and Security › App-Specific Passwords):
#        xcrun notarytool store-credentials kumquat-notary --apple-id you@example.com --team-id TEAMID
#
# Usage:
#   VERSION=1.2.0 scripts/notarize.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=kumquat-notary scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-kumquat-notary}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    echo "✗ No \"Developer ID Application\" certificate in your keychain." >&2
    echo "  Create one in Xcode › Settings › Accounts › Manage Certificates" >&2
    echo "  (requires an Apple Developer Program membership)." >&2
    exit 1
fi

SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh

APP="build/Kumquat.app"
DMG="build/Kumquat.dmg"
SUBMISSION="build/Kumquat-notarize.zip"

# Submits a file and waits; on rejection prints Apple's log and stops.
notarize() {
    local file="$1" result="build/notary-result.json" status id
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json > "$result"
    status="$(plutil -extract status raw -o - "$result")"
    id="$(plutil -extract id raw -o - "$result")"
    rm -f "$result"
    if [ "$status" != "Accepted" ]; then
        echo "✗ Notarization of $file finished with status \"$status\". Apple's log:" >&2
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        exit 1
    fi
}

echo "▸ Notarizing the app (usually a few minutes)…"
rm -f "$SUBMISSION"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
notarize "$SUBMISSION"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$SUBMISSION" build/Kumquat.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" build/Kumquat.zip

echo "▸ Notarizing the disk image…"
SIGN_IDENTITY="$SIGN_IDENTITY" APP="$APP" DMG="$DMG" scripts/make-dmg.sh
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "✓ Notarized: $DMG and build/Kumquat.zip — upload them to the GitHub release,"
echo "  then run scripts/update-cask.sh so Homebrew installs the new version."
