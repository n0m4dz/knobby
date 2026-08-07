#!/bin/bash
# Renders the app icon and packs Sources/Knobby/Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swift scripts/make-icon.swift "$TMP/icon_1024.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Sources/Knobby/Resources/AppIcon.icns
echo "Wrote Sources/Knobby/Resources/AppIcon.icns"
