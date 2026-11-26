import Cocoa

enum SelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST"] == "1"
    }

    static func run(coordinator: CaptureCoordinator, service: ScreenCaptureService) {
        guard isEnabled else { return }
        // 抓图耗时基准：BENCH=1 直接截图（冷启动），BENCH=2 先预热再截图。
        // 两者对比的就是「预热到底省了多少」这个数，不靠猜。
        if let bench = ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_BENCH"] {
            Task { @MainActor in
                guard let screen = NSScreen.screens.first else { NSApp.terminate(nil); return }
                if bench == "2" {
                    let start = CACurrentMediaTime()
                    await service.prewarm()
                    NSLog("PinSnap bench: prewarm \(ScreenCaptureService.ms(since: start))ms")
                }
                for run in 1...3 {
                    let start = CACurrentMediaTime()
                    _ = try? await service.snapshot(screen: screen)
                    NSLog("PinSnap bench: run\(run) \(ScreenCaptureService.ms(since: start))ms cache=\(service.hasWarmCache)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_SCREENS"] == "1" {
            Task { @MainActor in
                for screen in NSScreen.screens {
                    _ = try? await service.snapshot(screen: screen)
                }
                NSApp.terminate(nil)
            }
            return
        }
        NSLog("PinSnap self-test: starting capture")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let index = Int(ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_SCREEN_INDEX"] ?? "0") ?? 0
            if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_FASTDRAG"] == "1"
                || ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_CANCELDURINGCAPTURE"] == "1" {
                // 关键：不能用预设选区，否则直接进 editing，测不到 selecting 拖拽路径。
                coordinator.beginRegionCapture()
            } else if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_REGION"] == "1" {
                coordinator.beginRegionCaptureForTest(NSRect(x: 240, y: 220, width: 900, height: 560),
                                                      screenIndex: index)
            } else if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_PLACEHOLDER"] == "1" {
                // 走 selecting 阶段：没有工具栏挡住，转储出来的 alpha 才能直接反映遮罩本身。
                coordinator.beginRegionCapture()
            } else {
                // 全屏模式也支持指定屏幕，方便逐屏回归。
                let screens = NSScreen.screens
                coordinator.beginFullScreenCapture(on: screens.indices.contains(index) ? screens[index] : nil)
            }
        }
        // 占位期 vs 落位后：占位时窗口必须接近全透明（透出实时桌面，不能是黑屏）。
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_PLACEHOLDER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.03) {
                NSLog("PinSnap placeholder frame: \(coordinator.autotestDumpWhole(to: "/tmp/pinsnap-placeholder.png"))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.60) {
                NSLog("PinSnap loaded frame: \(coordinator.autotestDumpWhole(to: "/tmp/pinsnap-loaded.png"))")
                NSApp.terminate(nil)
            }
            return
        }
        // 几何自证必须在打标注之前跑，保证比的是纯底图。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) {
            NSLog("PinSnap self-test geometry: \(coordinator.autotestVerifyGeometry())")
            NSLog("PinSnap self-test selection resize: \(coordinator.autotestVerifySelectionResize())")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            coordinator.autotestSeedAnnotations()
            let result = coordinator.autotestExport(to: "/tmp/pinsnap-selftest.png")
            NSLog("PinSnap self-test export: \(result)")
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_DUMP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                let result = coordinator.autotestDumpView(to: "/tmp/pinsnap-view.png")
                NSLog("PinSnap self-test view dump: \(result)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) {
                let result = coordinator.autotestDumpBase(to: "/tmp/pinsnap-base.png")
                NSLog("PinSnap self-test base dump: \(result)")
            }
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_TOOLBAR"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                coordinator.autotestSeedAnnotations()
                NSLog("PinSnap toolbar dump: \(coordinator.autotestDumpToolbar(to: "/tmp/pinsnap-toolbar-render.png"))")
                NSLog("PinSnap palette shape: \(coordinator.autotestDumpPalette(text: false, to: "/tmp/pinsnap-palette-shape.png"))")
                NSLog("PinSnap palette text: \(coordinator.autotestDumpPalette(text: true, to: "/tmp/pinsnap-palette-text.png"))")
                NSLog("PinSnap editor dump: \(coordinator.autotestDumpEditorRegion(to: "/tmp/pinsnap-editor-render.png"))")
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_PALETTE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
                NSLog("PinSnap palette stability: \(coordinator.autotestPaletteStability())")
                NSLog("PinSnap palette shape: \(coordinator.autotestDumpPalette(text: false, to: "/tmp/pinsnap-palette-shape.png"))")
                NSLog("PinSnap palette text: \(coordinator.autotestDumpPalette(text: true, to: "/tmp/pinsnap-palette-text.png"))")
                NSLog("PinSnap toolbar dump: \(coordinator.autotestDumpToolbar(to: "/tmp/pinsnap-toolbar-render.png"))")
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_CANCELDURINGCAPTURE"] == "1" {
            // 1.0s 触发截图，1.15s 底图还没回来就按 Esc；3.0s 底图回来时不能凭空复活编辑器。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                NSLog("PinSnap cancel-mid-capture: \(coordinator.autotestCancel())")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                NSLog("PinSnap cancel-mid-capture result: editorPresent=\(coordinator.hasEditor)")
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_FASTDRAG"] == "1" {
            // 1.0s 触发区域截图；1.15s —— 抓图还没完成（冷启动 ~1.3s）——
            // 立刻模拟拖拽。修复后遮罩应已就绪并能直接画出选区。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                NSLog("PinSnap fastdrag: phase=\(coordinator.autotestPhaseName) editorPresent=\(coordinator.hasEditor)")
                NSLog("PinSnap fastdrag: \(coordinator.autotestSimulateDrag())")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NSLog("PinSnap fastdrag after snapshot: phase=\(coordinator.autotestPhaseName) editorPresent=\(coordinator.hasEditor)")
                NSLog("PinSnap fastdrag dump: \(coordinator.autotestDumpEditorRegion(to: "/tmp/pinsnap-fastdrag.png"))")
                NSLog("PinSnap fastdrag export: \(coordinator.autotestExport(to: "/tmp/pinsnap-fastdrag-export.png"))")
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_CANCEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                NSLog("PinSnap self-test cancel: \(coordinator.autotestCancel())")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                NSLog("PinSnap self-test alive after cancel, editorPresent=\(coordinator.hasEditor)")
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_PIN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                NSLog("PinSnap self-test pin: \(coordinator.autotestPin())")
            }
            if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_ZOOM"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) {
                    // 锚点取窗口内 27%,63% 处，确保确实落在窗口内
                    NSLog("PinSnap self-test zoom x2: \(coordinator.autotestZoom(factor: 2, atRelative: 0.27, 0.63))")
                    NSLog("PinSnap self-test zoom x0.25: \(coordinator.autotestZoom(factor: 0.25, atRelative: 0.27, 0.63))")
                    NSLog("PinSnap self-test zoom reset: \(coordinator.autotestZoom(factor: 4, atRelative: 0.27, 0.63))")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.8) {
                NSLog("PinSnap self-test alive after pin, pinned=\(coordinator.pinnedCount) editorPresent=\(coordinator.hasEditor)")
                if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_HOLD"] != "1" {
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_COPY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                NSLog("PinSnap self-test copy: \(coordinator.autotestCopy())")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                let pasted = NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
                NSLog("PinSnap self-test alive after copy, clipboardImage=\(pasted) editorPresent=\(coordinator.hasEditor)")
                NSApp.terminate(nil)
            }
            return
        }
        // 基础路径收尾：导出/转储完成后必须退出，
        // 否则自动化脚本会一直等（截图器本体是常驻的菜单栏程序，不会自己结束）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_HOLD"] == "1" {
                NSLog("PinSnap self-test holding, editorPresent=\(coordinator.hasEditor)")
                return
            }
            NSLog("PinSnap self-test done, editorPresent=\(coordinator.hasEditor)")
            NSApp.terminate(nil)
        }
    }
}
