# PinSnap

原生 macOS 截图与桌面 Pin 工具。界面使用 AppKit 手写，截图使用 ScreenCaptureKit；不使用 SwiftUI 或第三方 UI 库。

## 当前可用功能

- 菜单栏 + 主窗口双入口：区域截图（⌘⇧2）、全屏截图、窗口截图。
- **框选即编辑**：鼠标拖出选区后立即在原位进入标注，不再弹出独立预览窗口。
- 标注工具：矩形、**箭头**、编号（自动递增）、画笔、文字、马赛克。
- 撤销 / 重做、取消、复制、保存 PNG、Pin 到桌面。
- 复制 / 保存 / Pin 共用同一套“原图 + 标注”像素级合成结果。
- **清晰度**：截图按显示器原生像素抓取，预览与导出都按 1:1 铺满，不缩放、不插值；Pin 显示与导出图逐像素一致。
- Pin：`.floating` 悬浮窗口，默认 **1:1 原始尺寸**（只缩小不放大）；四边与四角可缩放（默认锁比例，按住 Shift 自由拉伸），可拖动，双击回到实际大小，右键有复制/保存/关闭菜单，Esc 关闭。
- Pin 支持 **滚轮 / 触控板捏合缩放**：以光标位置为锚点放大缩小，并显示当前百分比；拖拽、已合成标注不受影响。
- 快捷键使用 Carbon `RegisterEventHotKey`，系统级生效，不需要“输入监控”权限。

## 项目结构与模块职责

```text
pin-snap/
├── Sources/
│   ├── App/
│   │   ├── main.swift                    # 显式 NSApplication 入口
│   │   ├── AppDelegate.swift             # 生命周期、菜单栏、动作分发
│   │   ├── MainWindowController.swift    # 主窗口与权限状态
│   │   └── SelfTest.swift                # 环境变量驱动的自测（PINSNAP_AUTOTEST）
│   ├── Capture/
│   │   ├── CaptureSnapshot.swift         # 单帧快照（像素/点/缩放比）
│   │   ├── ScreenCaptureService.swift    # ScreenCaptureKit 全屏与窗口截图
│   │   ├── CaptureEditorWindow.swift     # 全屏覆盖层：框选 + 就地编辑 + 工具栏
│   │   └── CaptureCoordinator.swift      # 流程编排、窗口选择面板、错误呈现
│   ├── Editor/
│   │   └── Annotations.swift             # 标注模型、马赛克采样、渲染器
│   ├── Pin/
│   │   └── PinController.swift           # Pin 生命周期与悬浮窗口行为
│   └── Hotkeys/
│       └── HotkeyController.swift        # Carbon 全局快捷键
├── Scripts/
│   └── build.sh                          # swiftc 编译、组包和临时签名
└── build/PinSnap.app                     # 构建产物（不提交版本库）
```

### 模块边界

- `ScreenCaptureService` 只负责“拿到像素”：显示器按 `backingScaleFactor` 取原生像素，窗口截图按所在屏幕缩放比取原生像素。
- `CaptureEditorWindow` 是唯一交互层：框选、编辑、导出都在同一个覆盖层完成，没有中间预览步骤。
- `AnnotationRenderer` 同时服务屏幕预览与导出，二者使用同一坐标系与同一马赛克采样网格，因此“看到的”等于“导出的”。
- 底图统一走 `CGContext.drawUprightCGImage(_:in:quality:)`：视图与导出上下文都是“左上原点、y 向下”，1:1 时用 `.none` 关闭插值，避免 `NSImage` 缓存带来的额外重采样。
- 导出画布直接使用裁剪出的真实像素尺寸（`cropped.width × cropped.height`），底图铺满画布，因此映射严格 1:1；不再用 `.integral` 扩张裁剪矩形。
- `PinController` 强持有每个 `PinnedWindow`，避免窗口刚显示就因无引用被释放。
- Pin 的滚轮缩放只改窗口 frame：窗口尺寸即图片尺寸，缩放锚点按光标在窗口内的相对位置反算新原点，所以光标下的内容保持不动，已合成的标注天然跟随。

## 主要交互流程

1. 触发区域截图：隐藏主窗口 → 等 180ms → ScreenCaptureKit 抓一帧冻结画面。
2. 覆盖层显示冻结画面并压暗，拖动框选后松手立即进入编辑态（工具栏贴在选区下方）。
3. 工具栏编辑标注；`⌘Z`/`⇧⌘Z` 撤销重做，`Return` 复制，`⌘S` 保存，`Esc` 取消。
4. 复制 / 保存 / Pin 都调用 `renderSelection()`：按原生像素裁剪 + 重绘标注。
5. Pin 创建无边框 `NSPanel`：`level = .floating`，`canJoinAllSpaces` / `fullScreenAuxiliary`。

## 构建与运行

系统要求：macOS 14+、Command Line Tools（不需要完整 Xcode）。

在仓库根目录执行：

```bash
./Scripts/build.sh
ditto build/PinSnap.app /Applications/PinSnap.app
codesign --force --deep --sign - /Applications/PinSnap.app
open /Applications/PinSnap.app
```

构建脚本会生成标准 `.app` 包，并使用本机临时签名。正式分发时改为 Developer ID 签名、Notarization 和 stapling。

## 权限、沙盒与兼容性

### 必需权限

1. **屏幕录制**：系统设置 → 隐私与安全性 → 屏幕录制 → 允许 PinSnap。这是唯一必需权限。
2. **输入监控**：本版本**不需要**。快捷键走 Carbon `RegisterEventHotKey`，属于系统级热键注册，不依赖事件监听。
3. **辅助功能**：不需要。不做模拟鼠标键盘。
4. **文件访问**：通过 `NSSavePanel` 让用户选位置，不索取完整磁盘访问权限。

> 开发期注意：每次重新构建 + 重新 `codesign -s -` 都会改变代码签名，系统可能把新二进制视为另一个应用，导致原有屏幕录制授权失效。遇到“已勾选仍失败”时，先在系统设置中 `-` 移除 PinSnap，再重新添加当前 `/Applications/PinSnap.app`。

### 兼容性策略

- 最低版本：**macOS 14**。截图宽高按 `display.width × backingScaleFactor` 计算，导出按同一比例生成位图，避免放大模糊。
- 多显示器：以目标 `NSScreen` 的 `screenFrame` 定位覆盖层，坐标在窗口内局部化，避免全局坐标错位。
- HDR：当前以 SDR 为目标。若要保留 HDR，需在 macOS 15+ 使用 HDR 截图预设并改造导出管线。
- 沙盒：先以非沙盒、Developer ID 公证验证截图体验；上架 App Store 需单独验证 ScreenCaptureKit 授权与文件书签。
- 锁屏与登录前：不作为无人值守截图方案，锁屏内容视为不可用。

## AppKit 实现注意事项

- 自定义 `NSWindow` 子类不要调用带 `screen:` 的便利构造器，它会回调子类的 `init(contentRect:styleMask:backing:defer:)`；未覆盖该路径会直接 `SIGTRAP`。
- 代码创建的窗口必须显式 `isReleasedWhenClosed = false`。默认值为 `true`，AppKit 会在 `close()` 时再 release 一次，ARC 再释放一次即过度释放，崩溃栈表现为 `objc_release` / `SIGSEGV`。
- 在窗口自己的方法里调用回调清理外部强引用时，先用局部 `let strongSelf = self` 保活，避免方法执行中途被释放。
- 覆盖层窗口使用 `.borderless` + `level = .screenSaver` + `canBecomeKey = true`，否则收不到键盘事件。
- 手动摆放 frame 的工具条不要在 `layout()` 里反复赋值 frame，否则可能触发布局循环导致主线程卡死；只在状态变化时定位一次。
- 工具栏包含真实 `NSButton` 子视图，命中测试交给 AppKit；画布 `mouseDown` 仅在选区内生效，避免误抢按钮点击。
- 导出走 `CGContext` 而不是 `NSBitmapImageRep`：后者在 Retina 上会引入额外的点/像素换算，容易偏色且难以对齐标注坐标。
- 位图上下文的用户空间是**像素**，不是 `NSImage.size` 的点。必须先 `scaleBy(pixel/point)` 再翻转成左上原点，否则 Retina 屏上内容只会画进左下角 1/4，其余留白。
- 画布色彩空间沿用源图 `CGImage.colorSpace`，最后用 `makeImage()` 取结果，避免二次色彩转换造成偏色。
- **`CGImage.cropping(to:)` 用的是左上原点**，而翻转视图里的 `selection.minY` 本身也是从上往下量，两者天然一致，不要再翻到底部原点。多做一次 `H - y - h` 会让选区垂直错开 `H - 2y - h` 像素——这就是「框选内容和导出图片对不上」的根因，且全屏截图（`y=0` 且满高）时是恒等变换，bug 会被完全掩盖。
- 1:1 绘制时使用 `.none` 插值，非 1:1 时才用 `.high`；窗口位置按 `backingScaleFactor` 对齐到整数像素，避免半像素重采样导致发虚。
- Pin 窗口初始尺寸不做放大，整屏截图刚好 1:1，保证清晰；放大后打开“实际大小”可恢复。
- Pin 窗口采用原生 `.resizable`，系统负责边缘缩放；拖动逻辑只在内容区响应。

## 自测入口

```bash
PINSNAP_AUTOTEST=1 PINSNAP_AUTOTEST_REGION=1 \
  ./build/PinSnap.app/Contents/MacOS/PinSnap
```

会导出到 `/tmp/pinsnap-selftest.png`，用于验证渲染与像素密度。追加以下变量可验证对应退出路径：

```bash
PINSNAP_AUTOTEST=1 PINSNAP_AUTOTEST_COPY=1   # 复制后进程存活、剪贴板有图
PINSNAP_AUTOTEST=1 PINSNAP_AUTOTEST_PIN=1    # Pin 后 pinned=1、编辑器已关闭
PINSNAP_AUTOTEST=1 PINSNAP_AUTOTEST_CANCEL=1 # 取消后编辑器已关闭
PINSNAP_AUTOTEST=1 PINSNAP_AUTOTEST_PIN=1 PINSNAP_AUTOTEST_ZOOM=1  # 校验缩放锚点不动
```

`PINSNAP_AUTOTEST_ZOOM=1` 会打印 `anchorX/anchorY` 在缩放前后的相对位置；两者相等即表示“以光标为中心”成立。

自测还支持：

```bash
PINSNAP_AUTOTEST_SCREEN_INDEX=1   # 指定屏幕（0=主屏，1=内建 Retina 屏），全屏/区域截图都生效
PINSNAP_AUTOTEST_DUMP=1           # 转储原始快照、编辑器所见选区，供像素比对
PINSNAP_AUTOTEST_HOLD=1           # 跑完不退出，便于人工观察
```

### 几何回归（防「框选与导出错位」）

```bash
Scripts/verify-geometry.sh 0   # 外接屏
Scripts/verify-geometry.sh 1   # 内建 Retina 屏
```

脚本会在指定屏上用固定选区 `(240,220,900,560)` 跑一次截图，然后用 `Scripts/tools/imgalign.swift` 在原始快照中**独立搜索**导出图的实际位置，要求它恰好等于 `选区原点 × 缩放比`。

两个屏幕的期望输出：

```
外接屏（scale 1）： offset=(240,220)   平均差=0.00  >8:0.00%  最大差=0
内建屏（scale 2）： offset=(480,440)   平均差=0.00  >8:0.00%  最大差=0
```

`平均差=0.00 / 最大差=0` 表示导出图与编辑器所见画面**逐像素完全相同**。之所以能到 0，是因为转储时会临时置 `suppressChrome`，跳过选区描边、尺寸标签、把手这些 UI 装饰——否则那圈 1.5pt 描边会被算进选区内，产生约 0.58% 的假差异。

应用内也有一条不依赖外部工具的断言：`autotestVerifyGeometry()` 会把内部裁剪结果与「由选区独立换算出的像素矩形」逐像素比对，日志里输出 `PASS` / `FAIL`。这条断言在打标注之前执行，因此比较的是纯底图。

像素工具也可单独使用：

```bash
swift Scripts/tools/imgalign.swift find export.png base.png      # 归一化互相关定位
swift Scripts/tools/imgalign.swift crop in.png out.png 240 220 900 560
swift Scripts/tools/imgalign.swift diff a.png b.png heat.png     # 差异统计 + 热力图
```

## 下一阶段开发顺序

1. 选区二次调整、裁剪与标注样式（颜色 / 粗细 / 字号）。
2. 窗口截图直接高亮鼠标下窗口，减少一次选择面板。
3. 快捷键自定义、截图历史与偏好持久化。
4. 多显示器、不同缩放、全屏 App、Spaces 的回归测试。
5. Developer ID 签名、公证、自动更新与崩溃收集。
