#!/bin/bash
# Publish a release that release.sh packaged:
#   ./scripts/publish.sh 1.3.0
# Copies releases/v<version>/ to the download site on DEPLOY_HOST (see update.conf) over SSH,
# then mirrors it to a GitHub release when GITHUB_REPO is set.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: publish.sh <version>}"
source update.conf
[[ -n "${DEPLOY_HOST:-}" && -n "${DEPLOY_DIR:-}" ]] || { echo "Set DEPLOY_HOST and DEPLOY_DIR in update.conf first." >&2; exit 1; }

OUT="releases/v$VERSION"
ZIP="$OUT/LaunchUS-$VERSION.zip"
DMG="$OUT/LaunchUS-$VERSION.dmg"
FEED="$OUT/appcast.xml"
for f in "$ZIP" "$DMG" "$FEED"; do
    [[ -f "$f" ]] || { echo "Missing $f — run ./scripts/release.sh $VERSION first." >&2; exit 1; }
done

DL="$DEPLOY_DIR/dl"
# rsync writes to a temporary name and renames, so nobody downloads half a file.
# The versioned files go first, then the "latest" dmg, and the feed last, so the feed never
# lists a file that isn't up yet.
ssh "$DEPLOY_HOST" "mkdir -p '$DL/v$VERSION'"
rsync -t --progress "$ZIP" "$DMG" "$DEPLOY_HOST:$DL/v$VERSION/"
rsync -t "$DMG" "$DEPLOY_HOST:$DL/LaunchUS.dmg"
rsync -t "$FEED" "$DEPLOY_HOST:$DL/appcast.xml"
echo "Published $VERSION to $DOWNLOAD_URL"

if [[ -n "${GITHUB_REPO:-}" ]]; then
    NOTES=(--notes "")
    [[ -f "$OUT/LaunchUS-$VERSION.md" ]] && NOTES=(--notes-file "$OUT/LaunchUS-$VERSION.md")
    # appcast.xml too: 1.2.2 and earlier check github.com/<repo>/releases/latest/download/appcast.xml,
    # and its download links point at the download site, so they update from there.
    gh release create "v$VERSION" "$DMG" "$ZIP" "$FEED" --repo "$GITHUB_REPO" --target main \
        --title "LaunchUS $VERSION" "${NOTES[@]}"
fi
