#!/bin/bash
# Requires a bundled build and a local window server; XTD_START_MODE exercises both layouts.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="build/XTransDarkroom.app/Contents/MacOS/XTransDarkroom"
if [ ! -x "$BIN" ]; then
    echo "Missing bundled app; run ./Scripts/bundle.sh release first."
    exit 1
fi
LOG_DIR="$(mktemp -d)"
PID=""
cleanup() {
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -rf "$LOG_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for MODE in library develop; do
    if [ "$MODE" = develop ]; then
        XTD_START_MODE=develop "$BIN" > /dev/null 2>"$LOG_DIR/$MODE.stderr" &
    else
        env -u XTD_START_MODE "$BIN" > /dev/null 2>"$LOG_DIR/$MODE.stderr" &
    fi
    PID=$!
    for ((POLL = 0; POLL < 16; POLL++)); do
        perl -e 'select undef, undef, undef, 0.5'
        if ! kill -0 "$PID" 2>/dev/null; then
            wait "$PID" 2>/dev/null || true
            PID=""
            echo "SMOKE FAILED ($MODE)"
            head -n 20 "$LOG_DIR/$MODE.stderr"
            exit 1
        fi
    done
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
    echo "smoke ok ($MODE)"
done
