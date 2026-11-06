#!/bin/bash
# Package a release for in-app updates:
#   ./scripts/release.sh 0.5.0 [release-notes.md]
# Bumps the version in Resources/Info.plist, builds, zips the app and writes a signed
# appcast.xml into releases/v<version>/, plus a drag-to-install .dmg for first installs.
# Upload all three to a GitHub release tagged v<version>.
# Needs GITHUB_REPO in update.conf and the update signing key in the login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes.md]}"
NOTES="${2:-}"
source update.conf
[[ -n "${GITHUB_REPO:-}" ]] || { echo "Set GITHUB_REPO in update.conf first." >&2; exit 1; }

PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

./scripts/build.sh release

# One folder per release, so the appcast lists just this version (the feed always
# points at the latest release's appcast.xml).
OUT="releases/v$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/LaunchUS-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent build/LaunchUS.app "$ZIP"
[[ -n "$NOTES" ]] && cp "$NOTES" "$OUT/LaunchUS-$VERSION.md"

.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account LaunchUS \
    --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/" \
    --embed-release-notes "$OUT"

# After the appcast, so updates keep coming from the zip.
DMG="$OUT/LaunchUS-$VERSION.dmg"
./scripts/dmg.sh "$DMG"

echo
echo "Version $VERSION (build $BUILD) is ready. Publish it with:"
echo "  gh release create v$VERSION $DMG $ZIP $OUT/appcast.xml --repo $GITHUB_REPO --title $VERSION"
