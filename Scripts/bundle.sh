#!/bin/bash
# Assemble a launchable .app from the SwiftPM binary.
# Xcode is not installed, so there is no xcodebuild to produce a bundle for us.
set -euo pipefail
cd "$(dirname "$0")/.."

# CLT's default SDK (macOS 27) ships @State as a macro whose plugin only exists in Xcode;
# pin to 26.5, which still has the plugin, or every swift build fails.
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[ -d "$SDKROOT" ] || { echo "SDKROOT not found: $SDKROOT"; exit 1; }

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/XTransDarkroom"
APP="build/XTransDarkroom.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XTransDarkroom"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>X-Trans Darkroom</string>
  <key>CFBundleDisplayName</key><string>X-Trans Darkroom</string>
  <key>CFBundleIdentifier</key><string>local.xtransdarkroom</string>
  <key>CFBundleExecutable</key><string>XTransDarkroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# Ad-hoc signature: unsigned SwiftUI apps are refused a window server connection.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "$APP"
