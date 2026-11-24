#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PinSnap.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

# 版本号可由参数注入，保证 Release tag 与 app 内版本一致：
#   ./Scripts/build.sh 1.0.0 1
VERSION="${1:-1.0.0}"
BUILD_NUMBER="${2:-1}"

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
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
</dict></plist>
PLIST

# 必须在 codesign 之前改，签名覆盖 Info.plist。
# 用 PlistBuddy 而不是 sed：sed 在 macOS 上存在 BSD/GNU/toybox 等方言差异，
# `-i ''` 的写法并非到处可用，会让构建在签名前静默中断。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
echo "Built: $APP (version $VERSION, build $BUILD_NUMBER)"
