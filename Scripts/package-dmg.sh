#!/bin/zsh
# 把 build/PinSnap.app 打包成可分发的 dmg。
#
#   ./Scripts/package-dmg.sh [版本号] [输出路径]
#
# 版本号省略时取 Info.plist 里的 CFBundleShortVersionString；
# 输出路径省略时为 build/PinSnap-<版本>.dmg。
#
# 前置：先跑 ./Scripts/build.sh <版本>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PinSnap.app"

if [[ ! -d "$APP" ]]; then
  echo "找不到 $APP，请先运行 ./Scripts/build.sh"
  exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
OUT="${2:-$ROOT/build/PinSnap-$VERSION.dmg}"

# 签名校验不通过就不打包，避免把坏包发出去。
if ! codesign --verify --deep "$APP" 2>/dev/null; then
  echo "签名校验失败，终止打包：$APP"
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pinsnap-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# ditto 保留签名与扩展属性；cp -R 可能破坏代码签名。
ditto "$APP" "$STAGE/PinSnap.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create \
  -volname "PinSnap $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUT" > /dev/null

echo "DMG : $OUT"
echo "大小: $(du -h "$OUT" | cut -f1)"
echo "SHA256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
