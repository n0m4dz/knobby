#!/bin/bash
# Builds, signs with a stable identity, and runs Knobby.
#
# The explicit designated requirement makes macOS validate TCC permissions
# (Accessibility, System Audio Recording) by identifier instead of code hash,
# so grants survive rebuilds. Always launch the dev build through this script.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTIFIER="com.n0m4dz.knobby"
BINARY=".build/debug/Knobby"

swift build
codesign --force --sign - \
    --identifier "$IDENTIFIER" \
    --requirements "=designated => identifier \"$IDENTIFIER\"" \
    "$BINARY"

exec "$BINARY"
