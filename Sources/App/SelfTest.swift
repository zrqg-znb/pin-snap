import Cocoa

enum SelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST"] == "1"
    }

    static func run(coordinator: CaptureCoordinator, service: ScreenCaptureService) {
        guard isEnabled else { return }
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
            if ProcessInfo.processInfo.environment["PINSNAP_AUTOTEST_REGION"] == "1" {
                coordinator.beginRegionCaptureForTest(NSRect(x: 240, y: 220, width: 900, height: 560),
                                                      screenIndex: index)
            } else {
                // 全屏模式也支持指定屏幕，方便逐屏回归。
                let screens = NSScreen.screens
                coordinator.beginFullScreenCapture(on: screens.indices.contains(index) ? screens[index] : nil)
            }
        }
        // 几何自证必须在打标注之前跑，保证比的是纯底图。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) {
            NSLog("PinSnap self-test geometry: \(coordinator.autotestVerifyGeometry())")
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
