#!/bin/bash
# Sends an app or disk image to Apple's notary service and staples the ticket to it:
#   ./scripts/notarize.sh build/LaunchUS.app
#   ./scripts/notarize.sh releases/v1.8.0/LaunchUS-1.8.0.dmg
# Does nothing unless NOTARY_PROFILE names a notarytool keychain profile, made once with
#   xcrun notarytool store-credentials LaunchUS --apple-id <Apple ID> --team-id <team> --password <app-specific password>
# and the item is signed with a "Developer ID Application" certificate (SIGN_IDENTITY).
set -euo pipefail
ITEM="${1:?usage: notarize.sh <LaunchUS.app | file.dmg>}"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Not notarized (NOTARY_PROFILE isn't set): $ITEM"
    exit 0
fi
SUBMIT="$ITEM"
if [[ -d "$ITEM" ]]; then  # an .app goes up as a zip
    SUBMIT="$(mktemp -d)/$(basename "$ITEM").zip"
    ditto -c -k --sequesterRsrc --keepParent "$ITEM" "$SUBMIT"
fi
echo "Notarizing $ITEM (usually a few minutes)…"
OUTPUT=$(xcrun notarytool submit "$SUBMIT" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$OUTPUT" | grep -E "id:|status:" | sort -u
if ! echo "$OUTPUT" | grep -q "status: Accepted"; then
    ID=$(echo "$OUTPUT" | awk '/id:/ {print $2; exit}')
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" || echo "$OUTPUT"
    echo "Notarization failed for $ITEM" >&2
    exit 1
fi
xcrun stapler staple -q "$ITEM"
[[ "$SUBMIT" != "$ITEM" ]] && rm -rf "$(dirname "$SUBMIT")"
echo "Notarized and stapled $ITEM"
