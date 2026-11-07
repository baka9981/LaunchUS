#!/bin/bash
# Build LaunchUS and package it as build/LaunchUS.app.
# Signs with SIGN_IDENTITY, else the "LaunchUS Local Signing" certificate when it's in the
# keychain, else ad-hoc. A fixed identity keeps privacy permissions (Accessibility, Full Disk
# Access) across rebuilds; ad-hoc builds lose them each time.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# Shortcuts actions (App Intents): the compiler records their definitions, and
# appintentsmetadataprocessor turns them into Metadata.appintents, as Xcode would.
INTENTS_DIR="$(mktemp -d)"
cat > "$INTENTS_DIR/protocols.json" <<'JSON'
["AppIntent","SetFocusFilterIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]
JSON
# Release builds compile the module as a whole, so one file holds every value.
INTENT_FLAGS=()
if [[ "$CONFIG" == "release" ]]; then
    INTENT_FLAGS=(-Xswiftc -emit-const-values-path -Xswiftc "$INTENTS_DIR/LaunchUS.swiftconstvalues"
                  -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$INTENTS_DIR/protocols.json")
fi
swift build -c "$CONFIG" ${INTENT_FLAGS[@]+"${INTENT_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${INTENT_FLAGS[@]+"${INTENT_FLAGS[@]}"} --show-bin-path)"

APP="build/LaunchUS.app"
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
        --platform-family macOS --deployment-target "$MIN_OS" --target-triple "$(uname -m)-apple-macos$MIN_OS" \
        --binary-file "$BIN_DIR/LaunchUS" --source-file-list "$INTENTS_DIR/sources.txt" \
        --swift-const-vals-list "$INTENTS_DIR/constvals.txt" --compile-time-extraction \
        --deployment-aware-processing --no-app-shortcuts-localization 2>&1 | grep -iE "error|warning" || true
    [[ -d "$APP/Contents/Resources/Metadata.appintents" ]] || echo "warning: Shortcuts actions metadata was not generated"
else
    echo "note: Shortcuts actions are only included in release builds"
fi
rm -rf "$INTENTS_DIR"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Update feed from update.conf (FEED_URL in the environment wins).
source update.conf
if [[ -z "${FEED_URL:-}" && -n "${DOWNLOAD_URL:-}" ]]; then
    FEED_URL="$DOWNLOAD_URL/appcast.xml"
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

LOCAL_IDENTITY="LaunchUS Local Signing"
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
    SIGN_IDENTITY="$LOCAL_IDENTITY"
fi
# Inside out: Sparkle's helpers, the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$item" 2>&1 | { grep -v "replacing existing" || true; }
done
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP" 2>&1 | { grep -v "replacing existing" || true; }
echo "Built $APP"
