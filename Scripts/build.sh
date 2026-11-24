#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PinSnap.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

swiftc -framework Cocoa -framework ScreenCaptureKit -framework Carbon \
  "$ROOT"/Sources/App/*.swift \
  "$ROOT"/Sources/Capture/*.swift \
  "$ROOT"/Sources/Editor/*.swift \
  "$ROOT"/Sources/Pin/*.swift \
  "$ROOT"/Sources/Hotkeys/*.swift \
  -o "$MACOS/PinSnap"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PinSnap</string>
  <key>CFBundleIdentifier</key><string>com.pinsnap.app</string>
  <key>CFBundleDisplayName</key><string>PinSnap</string>
  <key>CFBundleName</key><string>PinSnap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built: $APP"
