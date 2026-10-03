#!/bin/bash
# The project's verification gate. Run this before every commit.
#
# `swift run Checks` alone is not sufficient: it only builds the targets Checks depends on,
# so a compile error in App (the SwiftUI layer) passes unnoticed. That happened once and a
# broken build reached a commit. Build everything first, then run the checks.
set -euo pipefail
cd "$(dirname "$0")/.."

# CLT's default SDK (macOS 27) ships @State as a macro whose plugin only exists in Xcode;
# pin to 26.5, which still has the plugin, or every swift build fails.
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[ -d "$SDKROOT" ] || { echo "SDKROOT not found: $SDKROOT"; exit 1; }

echo "── building all targets ──"
swift build 2>&1 | grep -E "error|warning: unre" && { echo "BUILD FAILED"; exit 1; } || true
swift build >/dev/null

echo "── running checks ──"
swift run Checks

# Launch checks need a GPU/window server; headless callers use SKIP_SMOKE=1.
if [ "${SKIP_SMOKE:-0}" != 1 ]; then
    ./Scripts/bundle.sh release
    ./Scripts/smoke.sh
fi

echo "── all green ──"
