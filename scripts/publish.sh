#!/bin/bash
# Publish a release that release.sh packaged:
#   ./scripts/publish.sh 1.3.0
# Copies releases/v<version>/ to the download site on DEPLOY_HOST (see update.conf) over SSH,
# keeps the version it replaces for a rollback and removes the older ones there, then mirrors it to a GitHub release when GITHUB_REPO is set
# (GitHub keeps every version).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: publish.sh <version>}"
source update.conf
[[ -n "${DEPLOY_HOST:-}" && -n "${DEPLOY_DIR:-}" ]] || { echo "Set DEPLOY_HOST and DEPLOY_DIR in update.conf first." >&2; exit 1; }

OUT="releases/v$VERSION"
ZIP="$OUT/LaunchUS-$VERSION.zip"
DMG="$OUT/LaunchUS-$VERSION.dmg"
FEED="$OUT/appcast.xml"
# The Intel build: its own update zip, dmg and feed.
INTEL_ZIP="$OUT/LaunchUS-$VERSION-Intel.zip"
INTEL_DMG="$OUT/LaunchUS-$VERSION-Intel.dmg"
INTEL_FEED="$OUT/appcast-intel.xml"
for f in "$ZIP" "$DMG" "$FEED" "$INTEL_ZIP" "$INTEL_DMG" "$INTEL_FEED"; do
    [[ -f "$f" ]] || { echo "Missing $f — run ./scripts/release.sh $VERSION first." >&2; exit 1; }
done

DL="$DEPLOY_DIR/dl"
# rsync writes to a temporary name and renames, so nobody downloads half a file.
# The update zip goes first, then the dmg (only as LaunchUS.dmg, the latest), and the feed
# last, so the feed never lists a file that isn't up yet.
# The Intel build the same way: its zip next to the other, LaunchUS-Intel.dmg, appcast-intel.xml.
# The live version's dmgs and feeds go into its own folder first, so it can be put back.
OLD=$(ssh "$DEPLOY_HOST" "sed -n 's/.*<sparkle:shortVersionString>\\([^<]*\\)<.*/\\1/p' '$DL/appcast.xml' 2>/dev/null | head -n 1")
if [[ -n "$OLD" && "$OLD" != "$VERSION" ]]; then
    ssh "$DEPLOY_HOST" "cd '$DL' && [ -d 'v$OLD' ] && cp -p LaunchUS.dmg LaunchUS-Intel.dmg appcast.xml appcast-intel.xml 'v$OLD/' || true"
fi
ssh "$DEPLOY_HOST" "mkdir -p '$DL/v$VERSION'"
rsync -t --progress "$ZIP" "$INTEL_ZIP" "$DEPLOY_HOST:$DL/v$VERSION/"
rsync -t "$DMG" "$DEPLOY_HOST:$DL/LaunchUS.dmg"
rsync -t "$INTEL_DMG" "$DEPLOY_HOST:$DL/LaunchUS-Intel.dmg"
rsync -t "$FEED" "$DEPLOY_HOST:$DL/appcast.xml"
rsync -t "$INTEL_FEED" "$DEPLOY_HOST:$DL/appcast-intel.xml"
# The server keeps this release (the feed lists just it, and in-app updates from China need its
# zip here) and the one before it; older versions live on GitHub Releases.
ssh "$DEPLOY_HOST" "find '$DL' -mindepth 1 -maxdepth 1 -type d -name 'v*' ! -name 'v$VERSION' ! -name 'v${OLD:-none}' -exec rm -rf {} +"
echo "Published $VERSION to $DOWNLOAD_URL"

if [[ -n "${GITHUB_REPO:-}" ]]; then
    NOTES=(--notes "")
    [[ -f "$OUT/LaunchUS-$VERSION.md" ]] && NOTES=(--notes-file "$OUT/LaunchUS-$VERSION.md")
    # appcast.xml too: 1.2.2 and earlier check github.com/<repo>/releases/latest/download/appcast.xml,
    # and its download links point at the download site, so they update from there.
    gh release create "v$VERSION" "$DMG" "$ZIP" "$FEED" "$INTEL_DMG" "$INTEL_ZIP" "$INTEL_FEED" --repo "$GITHUB_REPO" --target main \
        --title "LaunchUS $VERSION" "${NOTES[@]}"
fi
