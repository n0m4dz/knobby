#!/bin/bash
# Notarizes and staples build/Knobby.app, producing build/Knobby-<version>.zip
# ready for a GitHub release.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials knobby-notary \
#       --apple-id "you@example.com" --team-id "TEAMID10" \
#       --password "app-specific-password"
#
# Then: scripts/make-app.sh && scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-knobby-notary}"
APP=build/Knobby.app

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/make-app.sh first." >&2; exit 1; }
# Capture first: pipefail + grep -q would misread codesign's SIGPIPE as failure.
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
if ! grep -q "Authority=Developer ID Application" <<<"$SIGN_INFO"; then
    echo "error: $APP is not Developer ID signed; notarization would be rejected." >&2
    echo "Install your 'Developer ID Application' certificate and re-run make-app.sh." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/Knobby-$VERSION.zip"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Staple the ticket so the app verifies offline, then re-zip for release.
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl --assess --type execute --verbose=2 "$APP"
echo "Notarized, stapled, and packaged: $ZIP"
