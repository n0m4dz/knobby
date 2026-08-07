#!/bin/bash
# Builds Knobby.app into build/.
#
# With a "Developer ID Application" certificate in the keychain (or one named
# via SIGN_IDENTITY), the app is signed with the hardened runtime so it can be
# notarized (scripts/notarize.sh). Without one it falls back to ad-hoc signing
# for local use.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

IDENTIFIER="com.n0m4dz.knobby"
APP=build/Knobby.app
ENTITLEMENTS=Sources/Knobby/Resources/Knobby.entitlements
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Knobby "$APP/Contents/MacOS/Knobby"
cp Sources/Knobby/Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Sources/Knobby/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi

if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" \
        --identifier "$IDENTIFIER" \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        "$APP"
    echo "Created $APP (signed: $IDENTITY)"
    echo "Notarize it with scripts/notarize.sh before distributing."
else
    # Stable designated requirement: TCC grants survive rebuilds.
    codesign --force --sign - \
        --identifier "$IDENTIFIER" \
        --requirements "=designated => identifier \"$IDENTIFIER\"" \
        "$APP"
    echo "Created $APP (ad-hoc signed — no Developer ID certificate found)."
fi
echo "Move it to /Applications and launch it from there."
