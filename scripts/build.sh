#!/bin/bash
# Build LaunchUS for one architecture and package it as an app:
#   ./scripts/build.sh [release|debug]                  this Mac's chip → build/LaunchUS.app
#   ARCH=x86_64 ./scripts/build.sh release              Intel           → build/x86_64/LaunchUS.app
# Apple silicon and Intel ship as separate apps (each half the size of a universal one);
# the Intel one reads its own update feed, so each Mac only ever gets its own build.
# Signs with SIGN_IDENTITY, else the "LaunchUS Local Signing" certificate when it's in the
# keychain, else ad-hoc. A fixed identity keeps privacy permissions (Accessibility, Full Disk
# Access) across rebuilds; ad-hoc builds lose them each time.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
HOST_ARCH="$(uname -m)"
ARCH="${ARCH:-$HOST_ARCH}"
case "$ARCH" in arm64|x86_64) ;; *) echo "ARCH must be arm64 or x86_64" >&2; exit 1 ;; esac
# A plain build for this Mac's chip, as before; --arch only for the other one.
ARCH_FLAGS=()
[[ "$ARCH" != "$HOST_ARCH" ]] && ARCH_FLAGS=(--arch "$ARCH")
# Shortcuts actions (App Intents): the compiler records their definitions, and
# appintentsmetadataprocessor turns them into Metadata.appintents, as Xcode would.
INTENTS_DIR="$(mktemp -d)"
cat > "$INTENTS_DIR/protocols.json" <<'JSON'
["AppIntent","SetFocusFilterIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]
JSON
# Release builds compile the module as a whole, so one file holds every value.
INTENT_FLAGS=()
if [[ "$CONFIG" == "release" ]]; then
    # Optimized for size: a sixth smaller, and the busy work happens in AppKit and SwiftUI anyway.
    INTENT_FLAGS=(-Xswiftc -Osize
                  -Xswiftc -emit-const-values-path -Xswiftc "$INTENTS_DIR/LaunchUS.swiftconstvalues"
                  -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$INTENTS_DIR/protocols.json")
fi
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} ${INTENT_FLAGS[@]+"${INTENT_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} ${INTENT_FLAGS[@]+"${INTENT_FLAGS[@]}"} --show-bin-path)"

if [[ "$ARCH" == "$HOST_ARCH" ]]; then APP="build/LaunchUS.app"; else APP="build/$ARCH/LaunchUS.app"; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LaunchUS" "$APP/Contents/MacOS/LaunchUS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Translations: keys are the Simplified Chinese text in the source.
for lproj in Resources/Localization/*.lproj; do
    ditto "$lproj" "$APP/Contents/Resources/$(basename "$lproj")"
done
if [[ -f "$INTENTS_DIR/LaunchUS.swiftconstvalues" ]]; then
    find "$PWD/Sources/LaunchUS" -name "*.swift" | sort > "$INTENTS_DIR/sources.txt"
    echo "$INTENTS_DIR/LaunchUS.swiftconstvalues" > "$INTENTS_DIR/constvals.txt"
    TOOLCHAIN="$(cd "$(dirname "$(xcrun --find swiftc)")/../.." && pwd)"
    MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)"
    xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" --toolchain-dir "$TOOLCHAIN" \
        --module-name LaunchUS --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
        --platform-family macOS --deployment-target "$MIN_OS" --target-triple "$ARCH-apple-macos$MIN_OS" \
        --binary-file "$BIN_DIR/LaunchUS" --source-file-list "$INTENTS_DIR/sources.txt" \
        --swift-const-vals-list "$INTENTS_DIR/constvals.txt" --compile-time-extraction \
        --deployment-aware-processing --no-app-shortcuts-localization 2>&1 | grep -iE "error|warning" || true
    [[ -d "$APP/Contents/Resources/Metadata.appintents" ]] || echo "warning: Shortcuts actions metadata was not generated"
else
    echo "note: Shortcuts actions are only included in release builds"
fi
rm -rf "$INTENTS_DIR"
mkdir -p "$APP/Contents/Frameworks"
# Sparkle comes universal; keep only this build's architecture.
ditto --arch "$ARCH" "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Nor what an app that isn't sandboxed never uses: headers, the XPC services (only for sandboxed
# apps; Info.plist doesn't turn them on) and languages LaunchUS isn't in.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE"/{Headers,PrivateHeaders,Modules,XPCServices} "$SPARKLE"/Versions/B/{Headers,PrivateHeaders,Modules,XPCServices}
find "$SPARKLE/Versions/B/Resources" -maxdepth 1 -name "*.lproj" \
    ! -name Base.lproj ! -name ja.lproj ! -name "zh_*.lproj" -exec rm -rf {} +

# Update feed from update.conf (FEED_URL in the environment wins).
source update.conf
if [[ -z "${FEED_URL:-}" && -n "${DOWNLOAD_URL:-}" ]]; then
    # Intel builds have their own feed, so each Mac only gets its own build.
    if [[ "$ARCH" == "x86_64" ]]; then FEED_URL="$DOWNLOAD_URL/appcast-intel.xml"; else FEED_URL="$DOWNLOAD_URL/appcast.xml"; fi
fi
if [[ -n "${FEED_URL:-}" ]]; then
    # Checks once a day without asking first (the Mac stays on for weeks, and Sparkle's
    # timer keeps going while LaunchUS runs); turning it off in Settings is remembered.
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" \
        -c "Add :SUEnableAutomaticChecks bool true" \
        -c "Add :SUScheduledCheckInterval integer 86400" "$APP/Contents/Info.plist"
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/LaunchUS" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Release builds ship without symbols (two thirds of the executable). The symbols go to a
# dSYM next to the app, which turns crash-log addresses back into names; it isn't shipped.
if [[ "$CONFIG" == "release" ]]; then
    DSYM="${APP%.app}.app.dSYM"
    rm -rf "$DSYM"
    xcrun dsymutil "$APP/Contents/MacOS/LaunchUS" -o "$DSYM" 2>&1 | grep -iv "no debug symbols" || true
    xcrun strip -S -x "$APP/Contents/MacOS/LaunchUS"
fi

LOCAL_IDENTITY="LaunchUS Local Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
    SIGN_IDENTITY="$LOCAL_IDENTITY"
fi
# Inside out: Sparkle's helpers, the framework, then the app.
for item in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$item" 2>&1 | { grep -v "replacing existing" || true; }
done
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP" 2>&1 | { grep -v "replacing existing" || true; }
echo "Built $APP"
