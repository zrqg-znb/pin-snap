#!/bin/zsh
# 几何回归：验证「框选到的区域」与「最终导出的图片」严格一致。
#
# 用法： Scripts/verify-geometry.sh [屏幕序号，默认 0]
#
# 原理：
#   1. 用固定的测试选区 (240,220,900,560) 在指定屏上跑一次区域截图，
#      同时转储「原始快照」和「编辑器里实际看到的选区画面」。
#   2. 用 imgalign 在快照中搜索导出图的位置，期望恰好等于 选区原点 × 缩放比。
#   3. 再和「所见选区」做逐像素比较，期望平均差极小。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/PinSnap.app/Contents/MacOS/PinSnap"
INDEX="${1:-0}"
TMP=/tmp/pinsnap-verify
mkdir -p "$TMP"

if [[ ! -x "$BIN" ]]; then
  echo "先构建： $ROOT/Scripts/build.sh"
  exit 1
fi

echo "== 运行自测（屏幕 #$INDEX）=="
PINSNAP_AUTOTEST=1 PINSNAP_AUTOTEST_REGION=1 \
PINSNAP_AUTOTEST_SCREEN_INDEX="$INDEX" PINSNAP_AUTOTEST_DUMP=1 \
  "$BIN" >"$TMP/run.log" 2>&1 &
APP_PID=$!
wait $APP_PID 2>/dev/null
sed -n 's/.*PinSnap\[[0-9:]*\] //p' "$TMP/run.log" | grep -E "screen=|self-test" || true

SCALE=$(sed -n 's/.*scale=\([0-9.]*\).*/\1/p' "$TMP/run.log" | head -1)
if [[ -z "${SCALE:-}" ]]; then
  echo "✗ 没能从日志里读出屏幕缩放比"
  exit 1
fi

cp /tmp/pinsnap-base.png "$TMP/base.png" 2>/dev/null || { echo "✗ 缺少快照转储"; exit 1; }
cp /tmp/pinsnap-selftest.png "$TMP/export.png" 2>/dev/null || { echo "✗ 缺少导出图"; exit 1; }
cp /tmp/pinsnap-view.png "$TMP/view.png" 2>/dev/null || true

EXPECT_X=$(python3 -c "print(round(240*$SCALE))")
EXPECT_Y=$(python3 -c "print(round(220*$SCALE))")

echo ""
echo "== 1. 导出图在快照中的位置 =="
FOUND=$(swift "$ROOT/Scripts/tools/imgalign.swift" find "$TMP/export.png" "$TMP/base.png")
echo "  $FOUND   期望 offset=($EXPECT_X,$EXPECT_Y)"
GOT_X=$(echo "$FOUND" | sed -n 's/.*offset=(\([0-9-]*\),\([0-9-]*\)).*/\1/p')
GOT_Y=$(echo "$FOUND" | sed -n 's/.*offset=(\([0-9-]*\),\([0-9-]*\)).*/\2/p')
if [[ "$GOT_X" == "$EXPECT_X" && "$GOT_Y" == "$EXPECT_Y" ]]; then
  GEO="PASS"
else
  GEO="FAIL(漂移 dx=$((GOT_X-EXPECT_X)) dy=$((GOT_Y-EXPECT_Y)))"
fi

echo ""
echo "== 2. 导出图 vs 编辑器所见选区 =="
if [[ -f "$TMP/view.png" ]]; then
  swift "$ROOT/Scripts/tools/imgalign.swift" diff "$TMP/export.png" "$TMP/view.png" "$TMP/heat.png" | sed 's/^/  /'
else
  echo "  （无视图转储，跳过）"
fi

echo ""
echo "== 结论 =="
echo "  几何对齐：$GEO"

# 内置自证断言（不依赖外部工具，跑在应用里）
VERDICT=$(grep -o 'geometry: [A-Z]*.*' "$TMP/run.log" | head -1)
echo "  内置断言：${VERDICT:-未输出}"

if [[ "$GEO" == PASS ]]; then
  exit 0
fi
exit 1
