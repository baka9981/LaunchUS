#!/bin/bash
# Package a release for in-app updates:
#   ./scripts/release.sh 0.5.0 [release-notes.md]
# Bumps the version in Resources/Info.plist, builds the Apple silicon and the Intel app and
# writes into releases/v<version>/, for each, an update zip, its signed feed and a
# drag-to-install .dmg for first installs:
#   LaunchUS-<v>.zip        appcast.xml        LaunchUS-<v>.dmg         Apple silicon
#   LaunchUS-<v>-Intel.zip  appcast-intel.xml  LaunchUS-<v>-Intel.dmg   Intel
# Then ./scripts/publish.sh <version> uploads them. With SIGN_IDENTITY="Developer ID
# Application: …" and NOTARY_PROFILE set, the apps and dmgs are notarized too (notarize.sh).
# Needs DOWNLOAD_URL in update.conf and the update signing key in the login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes.md]}"
NOTES="${2:-}"
source update.conf
[[ -n "${DOWNLOAD_URL:-}" ]] || { echo "Set DOWNLOAD_URL in update.conf first." >&2; exit 1; }

PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

# build.sh puts this Mac's chip in build/LaunchUS.app and the other in build/<arch>/.
app_for() { if [[ "$1" == "$(uname -m)" ]]; then echo build/LaunchUS.app; else echo "build/$1/LaunchUS.app"; fi; }

# One folder per release, so each feed lists just this version (the feeds always point at
# the latest release). Each feed is generated in a folder holding only its own zip.
OUT="releases/v$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
for spec in "arm64 appcast.xml" "x86_64 appcast-intel.xml -Intel"; do
    read -r ARCH FEED SUFFIX <<< "$spec"
    ARCH="$ARCH" ./scripts/build.sh release
    APP="$(app_for "$ARCH")"
    # Before zipping, so the update zip carries the stapled app (no-op without NOTARY_PROFILE).
    ./scripts/notarize.sh "$APP"
    NAME="LaunchUS-$VERSION${SUFFIX:-}"
    STAGE="$OUT/.$ARCH"
    mkdir -p "$STAGE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/$NAME.zip"
    [[ -n "$NOTES" ]] && cp "$NOTES" "$STAGE/$NAME.md"
    .build/artifacts/sparkle/Sparkle/bin/generate_appcast --account LaunchUS \
        --download-url-prefix "$DOWNLOAD_URL/v$VERSION/" \
        --embed-release-notes "$STAGE"
    mv "$STAGE/$NAME.zip" "$OUT/"
    # generate_appcast names the feed after the app's SUFeedURL, which is $FEED.
    mv "$STAGE/$FEED" "$OUT/$FEED"
    [[ -f "$STAGE/$NAME.md" ]] && mv "$STAGE/$NAME.md" "$OUT/"
    rm -rf "$STAGE"
    # Symbols for reading this version's crash logs; stays here, publish.sh doesn't upload it.
    [[ -d "$APP.dSYM" ]] && ditto "$APP.dSYM" "$OUT/$NAME.dSYM"
    # After the appcast, so updates keep coming from the zip.
    ./scripts/dmg.sh "$OUT/$NAME.dmg" "$APP"
    ./scripts/notarize.sh "$OUT/$NAME.dmg"
done

echo
echo "Version $VERSION (build $BUILD) is ready. Publish it with:"
echo "  ./scripts/publish.sh $VERSION"
