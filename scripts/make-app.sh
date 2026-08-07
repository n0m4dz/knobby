#!/bin/bash
# Builds Knobby.app into build/ (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

IDENTIFIER="com.n0m4dz.knobby"
APP=build/Knobby.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Knobby "$APP/Contents/MacOS/Knobby"
cp Sources/Knobby/Resources/Info.plist "$APP/Contents/Info.plist"
# Stable designated requirement: TCC grants survive rebuilds.
codesign --force --sign - \
    --identifier "$IDENTIFIER" \
    --requirements "=designated => identifier \"$IDENTIFIER\"" \
    "$APP"

echo "Created $APP"
echo "Move it to /Applications and launch it from there."
