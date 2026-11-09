#!/bin/bash
# Publish a release that release.sh packaged:
#   ./scripts/publish.sh 1.3.0             a release: every Mac is offered it
#   ./scripts/publish.sh --beta 1.3.1      a beta: only Macs with 接收 Beta 版 on are offered it
#   ./scripts/publish.sh --promote 1.3.1   make the beta out now the release, no rebuild
#   ./scripts/publish.sh --withdraw-beta   take the beta back (Macs that installed it keep it)
# Copies releases/v<version>/ to the download site on DEPLOY_HOST (see update.conf) over SSH,
# keeps the release it replaces for a rollback and removes the older ones there, then mirrors it
# to a GitHub release when GITHUB_REPO is set (GitHub keeps every version; betas are prereleases,
# so github.com/…/releases/latest stays on the release).
#
# The feeds hold the release first and the beta, marked <sparkle:channel>beta</sparkle:channel>,
# after it (see scripts/appcast.py). A beta's zips and dmgs stay in v<version>/; LaunchUS.dmg is
# always the release. A beta becomes the release as it is, so build it with the next version.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=release
case "${1:-}" in
    --beta) MODE=beta; shift ;;
    --promote) MODE=promote; shift ;;
    --withdraw-beta) MODE=withdraw ;;
esac
[[ "$MODE" == withdraw ]] && VERSION="" || VERSION="${1:?usage: publish.sh [--beta|--promote] <version> | --withdraw-beta}"
source update.conf
[[ -n "${DEPLOY_HOST:-}" && -n "${DEPLOY_DIR:-}" ]] || { echo "Set DEPLOY_HOST and DEPLOY_DIR in update.conf first." >&2; exit 1; }

DL="$DEPLOY_DIR/dl"
FEEDS=(appcast.xml appcast-intel.xml)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# What is live now: the feeds as they are, and the release and beta they list.
for f in "${FEEDS[@]}"; do
    ssh "$DEPLOY_HOST" "cat '$DL/$f' 2>/dev/null" > "$TMP/live-$f" || true
done
{ read -r LIVE _; read -r BETA _; } < <(python3 scripts/appcast.py info "$TMP/live-appcast.xml")
[[ "$LIVE" == - ]] && LIVE=""
[[ "$BETA" == - ]] && BETA=""

# Keeps the release out now in its own folder (its dmgs and feeds), so the admin page can put it back.
keep_live() {
    [[ -n "$LIVE" && "$LIVE" != "$1" ]] || return 0
    ssh "$DEPLOY_HOST" "cd '$DL' && [ -d 'v$LIVE' ] && cp -p LaunchUS.dmg LaunchUS-Intel.dmg appcast.xml appcast-intel.xml 'v$LIVE/' || true"
}
# The feeds go up last, so they never list a file that isn't there yet.
put_feeds() {
    for f in "${FEEDS[@]}"; do rsync -t "$TMP/new-$f" "$DEPLOY_HOST:$DL/$f"; done
}
# The server keeps the release, the one before it and the beta; older versions live on GitHub.
clean_up() {
    local keep=""
    for v in "$@"; do [[ -n "$v" ]] && keep+=" ! -name 'v$v'"; done
    ssh "$DEPLOY_HOST" "find '$DL' -mindepth 1 -maxdepth 1 -type d -name 'v*' $keep -exec rm -rf {} +"
}
# A folder with LaunchUS.dmg in it holds a kept release (for a rollback): leave it.
drop_beta_dir() {
    [[ -n "$1" && "$1" != "$LIVE" ]] || return 0
    ssh "$DEPLOY_HOST" "cd '$DL' && [ ! -f 'v$1/LaunchUS.dmg' ] && rm -rf 'v$1' || true"
}

case "$MODE" in
release|beta)
    OUT="releases/v$VERSION"
    ZIP="$OUT/LaunchUS-$VERSION.zip"
    DMG="$OUT/LaunchUS-$VERSION.dmg"
    INTEL_ZIP="$OUT/LaunchUS-$VERSION-Intel.zip"
    INTEL_DMG="$OUT/LaunchUS-$VERSION-Intel.dmg"
    for f in "$ZIP" "$DMG" "$INTEL_ZIP" "$INTEL_DMG" "$OUT/appcast.xml" "$OUT/appcast-intel.xml"; do
        [[ -f "$f" ]] || { echo "Missing $f — run ./scripts/release.sh $VERSION first." >&2; exit 1; }
    done
    # Fails, before anything is uploaded, on a beta that isn't newer than what's out.
    for f in "${FEEDS[@]}"; do
        python3 scripts/appcast.py merge "$TMP/live-$f" "$OUT/$f" "--$MODE" > "$TMP/new-$f"
    done

    ssh "$DEPLOY_HOST" "mkdir -p '$DL/v$VERSION'"
    # rsync writes to a temporary name and renames, so nobody downloads half a file.
    rsync -t --progress "$ZIP" "$INTEL_ZIP" "$DEPLOY_HOST:$DL/v$VERSION/"
    if [[ "$MODE" == release ]]; then
        keep_live "$VERSION"
        rsync -t "$DMG" "$DEPLOY_HOST:$DL/LaunchUS.dmg"
        rsync -t "$INTEL_DMG" "$DEPLOY_HOST:$DL/LaunchUS-Intel.dmg"
        put_feeds
        # A beta ahead of this release stays (merge kept it in the feed); one behind is done.
        NEW_BETA=$(python3 scripts/appcast.py info "$TMP/new-appcast.xml" | sed -n '2s/ .*//p')
        [[ "$NEW_BETA" == - ]] && NEW_BETA=""
        clean_up "$VERSION" "$([[ "$LIVE" != "$VERSION" ]] && echo "$LIVE")" "$NEW_BETA"
        echo "Published $VERSION to $DOWNLOAD_URL"
    else
        # Beta testers who'd rather start fresh get its dmg from v<version>/.
        rsync -t "$DMG" "$INTEL_DMG" "$DEPLOY_HOST:$DL/v$VERSION/"
        put_feeds
        [[ "$BETA" != "$VERSION" ]] && drop_beta_dir "$BETA"
        echo "Published beta $VERSION: $DOWNLOAD_URL/v$VERSION/LaunchUS-$VERSION.dmg"
    fi

    if [[ -n "${GITHUB_REPO:-}" ]]; then
        NOTES=(--notes "")
        [[ -f "$OUT/LaunchUS-$VERSION.md" ]] && NOTES=(--notes-file "$OUT/LaunchUS-$VERSION.md")
        FLAGS=(--title "LaunchUS $VERSION")
        [[ "$MODE" == beta ]] && FLAGS=(--title "LaunchUS $VERSION Beta" --prerelease)
        # appcast.xml too: 1.2.2 and earlier check github.com/<repo>/releases/latest/download/appcast.xml,
        # and its download links point at the download site, so they update from there.
        # It's this release's own feed: a beta's lists the beta with no channel, but "latest" skips prereleases.
        gh release create "v$VERSION" "$DMG" "$ZIP" "$OUT/appcast.xml" "$INTEL_DMG" "$INTEL_ZIP" "$OUT/appcast-intel.xml" \
            --repo "$GITHUB_REPO" --target main "${FLAGS[@]}" "${NOTES[@]}"
    fi
    ;;

promote)
    if [[ "$BETA" == "$VERSION" ]]; then
        for f in "${FEEDS[@]}"; do python3 scripts/appcast.py promote "$TMP/live-$f" > "$TMP/new-$f"; done
        ssh "$DEPLOY_HOST" "cd '$DL' && test -f 'v$VERSION/LaunchUS-$VERSION.dmg' && test -f 'v$VERSION/LaunchUS-$VERSION-Intel.dmg'" \
            || { echo "The beta's dmgs aren't in $DL/v$VERSION/ on the server." >&2; exit 1; }
        keep_live "$VERSION"
        ssh "$DEPLOY_HOST" "cd '$DL' && cp -p 'v$VERSION/LaunchUS-$VERSION.dmg' .LaunchUS.dmg.tmp && mv .LaunchUS.dmg.tmp LaunchUS.dmg \
            && cp -p 'v$VERSION/LaunchUS-$VERSION-Intel.dmg' .LaunchUS-Intel.dmg.tmp && mv .LaunchUS-Intel.dmg.tmp LaunchUS-Intel.dmg"
        put_feeds
        clean_up "$VERSION" "$LIVE"
        echo "$VERSION is the release now."
    elif [[ "$LIVE" == "$VERSION" ]]; then
        echo "$VERSION is already the release on the download site (promoted from the admin page)."
    else
        echo "$VERSION isn't the beta out now (beta: ${BETA:-none}, release: ${LIVE:-none})." >&2
        exit 1
    fi
    if [[ -n "${GITHUB_REPO:-}" ]]; then
        gh release edit "v$VERSION" --repo "$GITHUB_REPO" --prerelease=false --latest --title "LaunchUS $VERSION"
        # Its feed there carries no channel and the download site's links, so 1.2.2 and earlier take it as is.
    fi
    ;;

withdraw)
    [[ -n "$BETA" ]] || { echo "There is no beta out now."; exit 0; }
    for f in "${FEEDS[@]}"; do python3 scripts/appcast.py withdraw "$TMP/live-$f" > "$TMP/new-$f"; done
    put_feeds
    drop_beta_dir "$BETA"
    echo "Beta $BETA withdrawn. Its GitHub prerelease stays; delete it there if you like."
    ;;
esac
