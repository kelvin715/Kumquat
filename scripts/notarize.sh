#!/bin/bash
# Builds Kumquat.app, signs it with your Developer ID, notarizes it with Apple and staples the
# ticket, so people can open the downloaded app without any Gatekeeper workaround.
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
SUBMISSION="build/Kumquat-notarize.zip"
RESULT="build/notary-result.json"

echo "▸ Submitting to Apple's notary service (usually a few minutes)…"
rm -f "$SUBMISSION"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait --output-format json > "$RESULT"
STATUS="$(plutil -extract status raw -o - "$RESULT")"
SUBMISSION_ID="$(plutil -extract id raw -o - "$RESULT")"
if [ "$STATUS" != "Accepted" ]; then
    echo "✗ Notarization finished with status \"$STATUS\". Apple's log:" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2 || true
    exit 1
fi

echo "▸ Stapling the notarization ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

rm -f "$SUBMISSION" "$RESULT" build/Kumquat.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" build/Kumquat.zip
echo "✓ Notarized: build/Kumquat.zip — upload it to the GitHub release."
