#!/bin/bash
# Wraps build/LaunchUS.app (or the given app) in a drag-to-install disk image:
#   ./scripts/dmg.sh <out.dmg> [path/to/LaunchUS.app]
# The window shows the app, an arrow and Applications on a drawn background
# (layout in dmg-background.swift: 1000×520, icons at x 330 and 670, y 260).
# Laying out the window drives Finder, so macOS may ask once to allow that.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: dmg.sh <out.dmg>}"
APP="${2:-build/LaunchUS.app}"
VOLUME=LaunchUS
[[ -d "$APP" ]] || { echo "Build the app first (scripts/build.sh release)." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Contents: the app, a link to Applications and the hidden background.
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/LaunchUS.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/dmg-background.swift "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

# A writable image to lay out, converted to a compressed read-only one at the end.
hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach -quiet -noautoopen -readwrite "$WORK/rw.dmg"

osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        try
            set pathbar visible of container window to false
        end try
        set sidebar width of container window to 0
        set the bounds of container window to {200, 120, 1200, 640}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 160
        set text size of opts to 14
        set background picture of opts to file ".background:background.tiff"
        set position of item "LaunchUS.app" of container window to {330, 260}
        set position of item "Applications" of container window to {670, 260}
        close
        open
        set the bounds of container window to {200, 120, 1200, 640}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# With "prefer tabs: always" and another Finder window open, the disk opens as a tab and
# Finder saves the positions but drops the background and icon size. Catch that here.
if ! grep -q pBBk "/Volumes/$VOLUME/.DS_Store" 2>/dev/null; then
    echo "Finder didn't save the window background. Close all Finder windows and run this again." >&2
    exit 1
fi

# The disk's own icon. Added after Finder is done, which otherwise drops it.
cp "$APP/Contents/Resources/AppIcon.icns" "/Volumes/$VOLUME/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOLUME"
sync
hdiutil detach -quiet "/Volumes/$VOLUME"
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULMO -o "$OUT"

# Same identity as the app (build.sh): SIGN_IDENTITY, else the local signing certificate.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT"
elif security find-identity -p codesigning | grep -q "LaunchUS Local Signing"; then
    codesign --force --sign "LaunchUS Local Signing" "$OUT"
fi
echo "Wrote $OUT"
