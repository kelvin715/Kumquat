#!/bin/bash
# Points the Homebrew cask (github.com/kelvin715/homebrew-tap) at a published release, so
# `brew install --cask kelvin715/tap/kumquat` and `brew upgrade` pick it up. Run it after the
# release's Kumquat.dmg is uploaded; it records that file's checksum, commits and pushes.
#   VERSION=1.2.0 scripts/update-cask.sh
set -euo pipefail

VERSION="${VERSION:?usage: VERSION=1.2.0 scripts/update-cask.sh}"
REPO="kelvin715/Kumquat"
TAP="kelvin715/homebrew-tap"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Downloading Kumquat.dmg from release v$VERSION…"
gh release download "v$VERSION" --repo "$REPO" --pattern Kumquat.dmg --dir "$WORK"
SHA="$(shasum -a 256 "$WORK/Kumquat.dmg" | cut -d ' ' -f 1)"

echo "▸ Updating the cask…"
gh repo clone "$TAP" "$WORK/tap" -- --quiet
sed -i '' -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
          -e "s/^  sha256 \".*\"$/  sha256 \"$SHA\"/" "$WORK/tap/Casks/kumquat.rb"

if git -C "$WORK/tap" diff --quiet; then
    echo "✓ The cask already installs $VERSION"
    exit 0
fi
git -C "$WORK/tap" commit --quiet --all --message "kumquat $VERSION"
git -C "$WORK/tap" push --quiet
echo "✓ brew now installs Kumquat $VERSION"
