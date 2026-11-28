import Cocoa
import ScreenCaptureKit

final class CaptureCoordinator {
    private enum CaptureState {
        case idle
        case capturing(Int)
        case editing(Int)
        case pickingWindow(Int)
    }

    var pinController: PinController?
    var historyStore: ScreenshotHistoryStore?
    var onEditorPresented: (() -> Void)?
    var onEditorClosed: (() -> Void)?

    private let captureService = ScreenCaptureService()
    private var editorWindow: CaptureEditorWindow?
    private var windowPicker: WindowPickerPanel?
    /// 每次截图请求的代号；用户在抓图回来前取消或发起新截图时递增，让在途结果作废。
    private var captureGeneration = 0
    private var captureState: CaptureState = .idle

    func beginRegionCapture(on screen: NSScreen? = nil) {
        // 用鼠标所在的屏幕，否则双屏时会在错误的那块屏上出现遮罩。
        guard let target = screen ?? Self.screenUnderMouse() else { return }
        requestSnapshot(screen: target,
                        presetSelection: nil,
                        centeredImage: false,
                        generation: beginNewSession())
    }

    /// 把 ScreenCaptureKit 的冷启动（枚举窗口 + 建立抓图通道，热机 200ms、老机器能到 1s+）
    /// 提前到 App 空闲时完成，用户按快捷键时只剩一次像素抓取。
    func prewarmCapture() {
        Task { [captureService] in
            await captureService.prewarm()
        }
    }

    func beginFullScreenCapture(on screen: NSScreen? = nil) {
        guard let target = screen ?? Self.screenUnderMouse() else { return }
        requestSnapshot(screen: target,
                        presetSelection: NSRect(origin: .zero, size: target.frame.size),
                        centeredImage: false,
                        generation: beginNewSession())
    }

    static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    func chooseWindowCapture() {
        let generation = beginNewSession()
        captureState = .pickingWindow(generation)
        Task { [weak self] in
            guard let self else { return }
            do {
                let windows = try await captureService.listCapturableWindows()
                await MainActor.run {
                    guard self.isCurrentSession(generation) else { return }
                    self.presentWindowPicker(windows: windows, generation: generation)
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrentSession(generation) else { return }
                    self.finishSession(generation: generation)
                    self.showCaptureError(error)
                }
            }
        }
    }

    /// 开始新会话时，主动关闭旧编辑器/选择器并使其异步结果失效。
    /// 不能仅覆盖 editorWindow 引用，否则旧的全屏窗口会残留并在关闭时误清空新会话。
    private func beginNewSession() -> Int {
        captureGeneration += 1
        let generation = captureGeneration
        if let windowPicker {
            windowPicker.orderOut(nil)
            self.windowPicker = nil
        }
        if let editorWindow {
            editorWindow.closeSilently()
            self.editorWindow = nil
            onEditorClosed?()
        }
        captureState = .capturing(generation)
        return generation
    }

    private func isCurrentSession(_ generation: Int) -> Bool {
        generation == captureGeneration
    }

    private func finishSession(generation: Int) {
        guard isCurrentSession(generation) else { return }
        editorWindow = nil
        windowPicker = nil
        captureState = .idle
        onEditorClosed?()
    }

    private func requestSnapshot(screen: NSScreen,
                                 presetSelection: NSRect?,
                                 centeredImage: Bool,
                                 generation: Int) {
        guard isCurrentSession(generation) else { return }
        captureState = .capturing(generation)
        onEditorPresented?()
        // 抓图要 1s+（ScreenCaptureKit 冷启动），这段时间不能是白屏：
        // 先挂上遮罩层立刻接管鼠标，等底图回来再原地填充。
        // 窗口截图（centeredImage）没有可预设的整屏坐标，保持抓完再弹出。
        if !centeredImage {
            let scale = max(screen.backingScaleFactor, 1)
            let placeholder = CaptureSnapshot(
                image: CGImageMini.placeholder,
                pixelSize: CGSize(width: screen.frame.width * scale,
                                  height: screen.frame.height * scale),
                screenFrame: screen.frame,
                scale: scale
            )
            presentEditor(snapshot: placeholder,
                          presetSelection: presetSelection,
                          centeredImage: false,
                          generation: generation)
        }
        Task { [weak self] in
            guard let self else { return }
            // 旧实现在这里等 120ms「让主窗口离开屏幕」，但那点延迟靠 SCK 的
            // excludingApplications 已经兜住了（PinSnap 的所有窗口都不会进底图），
            // 只留一小段让窗口事务落定，剩下的时间全交给抓图本身。
            try? await Task.sleep(nanoseconds: 20_000_000)
            do {
                let snapshot = try await captureService.snapshot(screen: screen)
                NSLog("PinSnap: snapshot ok \(snapshot.pixelSize)")
                await MainActor.run {
                    // 用户在底图回来前按了 Esc（或又发起了一次截图）：这张图作废，
                    // 否则会凭空弹出一个已经取消掉的遮罩。
                    guard generation == self.captureGeneration else {
                        NSLog("PinSnap: snapshot discarded (generation \(generation) != \(self.captureGeneration))")
                        return
                    }
                    if let window = self.editorWindow {
                        window.applySnapshot(snapshot)
                        self.captureState = .editing(generation)
                    } else if centeredImage {
                        self.presentEditor(snapshot: snapshot,
                                           presetSelection: presetSelection,
                                           centeredImage: centeredImage,
                                           generation: generation)
                    }
                }
            } catch {
                NSLog("PinSnap: snapshot failed \(error)")
                await MainActor.run {
                    // 占位遮罩已经挂出来了，失败必须收掉，否则会留下一块灰屏。
                    guard self.isCurrentSession(generation) else { return }
                    if let window = self.editorWindow {
                        window.closeSilently()
                    }
                    self.finishSession(generation: generation)
                    self.showCaptureError(error)
                }
            }
        }
    }

    private func presentEditor(snapshot: CaptureSnapshot,
                               presetSelection: NSRect?,
                               centeredImage: Bool,
                               generation: Int) {
        guard isCurrentSession(generation) else { return }
        let started = CACurrentMediaTime()
        NSApp.activate(ignoringOtherApps: true)
        let window = CaptureEditorWindow(snapshot: snapshot,
                                         presetSelection: presetSelection,
                                         pinController: pinController,
                                         historyStore: historyStore,
                                         centeredImage: centeredImage) { [weak self] in
            self?.editorClosed(generation: generation)
        }
        let builtAt = CACurrentMediaTime()
        editorWindow = window
        captureState = .editing(generation)
        // 先让覆盖层进屏幕和成为 key window，再交给下一轮 RunLoop 确认第一响应者。
        // 全局快捷键触发时，避免首个 mouseDown 被旧前台应用或空 first responder 吞掉。
        window.makeKeyAndOrderFront(nil)
        window.prepareForUserInput()
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            window.prepareForUserInput()
            NSLog("PinSnap: editor input ready key=\(window.isKeyWindow) firstResponder=\(String(describing: window.firstResponder))")
        }
        NSLog("PinSnap: editor presented build=\(ScreenCaptureService.ms(since: started))ms "
              + "orderFront=\(ScreenCaptureService.ms(since: builtAt))ms "
              + "screen=\(snapshot.screenFrame) window=\(window.frame) content=\(window.contentView?.frame ?? .zero) visible=\(window.isVisible) alpha=\(window.alphaValue) level=\(window.level.rawValue) behavior=\(window.collectionBehavior.rawValue) occlusion=\(window.occlusionState.rawValue) screen=\(window.screen?.localizedName ?? "nil")")
    }

    private func presentWindowPicker(windows: [SCWindow], generation: Int) {
        let picker = WindowPickerPanel(windows: windows) { [weak self] selected in
            guard let self, self.isCurrentSession(generation) else { return }
            self.windowPicker = nil
            guard let selected else {
                self.finishSession(generation: generation)
                return
            }
            self.captureState = .capturing(generation)
            Task {
                do {
                    let snapshot = try await self.captureService.capture(window: selected)
                    await MainActor.run {
                        guard self.isCurrentSession(generation) else { return }
                        self.presentEditor(snapshot: snapshot,
                                           presetSelection: nil,
                                           centeredImage: true,
                                           generation: generation)
                    }
                } catch {
                    await MainActor.run {
                        guard self.isCurrentSession(generation) else { return }
                        self.finishSession(generation: generation)
                        self.showCaptureError(error)
                    }
                }
            }
        }
        windowPicker = picker
        picker.presentAsModalOverlay()
    }

    private func editorClosed(generation: Int) {
        guard isCurrentSession(generation) else {
            NSLog("PinSnap: stale editor close ignored generation=\(generation) current=\(captureGeneration)")
            return
        }
        captureGeneration += 1
        editorWindow = nil
        captureState = .idle
        onEditorClosed?()
        // 刚用完就顺手把缓存刷一遍：窗口列表和分辨率都还是热的，下次截图不用再枚举。
        // 延迟两秒避开关闭动画和剪贴板写入，别跟用户正在做的事抢资源。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.prewarmCapture()
        }
    }

    func autotestExport(to path: String) -> String {
        guard let editorWindow, let cgImage = editorWindow.exportedCGImage() else { return "no-editor" }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "pixels=\(rep.pixelsWide)x\(rep.pixelsHigh) path=\(path)"
    }

    func dismissEditor() {
        guard let editorWindow else { return }
        let generation = captureGeneration
        editorWindow.closeSilently()
        finishSession(generation: generation)
    }

    func autotestDumpView(to path: String) -> String {
        guard let editorWindow else { return "no-editor" }
        return editorWindow.dumpViewBitmap(to: path)
    }

    func autotestDumpBase(to path: String) -> String {
        editorWindow?.dumpBaseImage(to: path) ?? "no-editor"
    }

    func autotestDumpWhole(to path: String) -> String {
        editorWindow?.dumpWholeView(to: path) ?? "no-editor"
    }

    func autotestDumpToolbar(to path: String) -> String {
        editorWindow?.autotestDumpToolbar(to: path) ?? "no-editor"
    }

    func autotestDumpPalette(text: Bool, to path: String) -> String {
        editorWindow?.autotestDumpPalette(text: text, to: path) ?? "no-editor"
    }

    func autotestDumpEditorRegion(to path: String) -> String {
        editorWindow?.autotestDumpEditorRegion(to: path) ?? "no-editor"
    }

    func autotestSimulateDrag() -> String {
        editorWindow?.autotestSimulateDrag() ?? "no-editor"
    }

    var autotestPhaseName: String { editorWindow?.autotestPhaseName ?? "no-editor" }

    func autotestPaletteStability() -> String { editorWindow?.autotestPaletteStability() ?? "no-editor" }

    func beginRegionCaptureForTest(_ rect: NSRect, screenIndex: Int = 0) {
        let screens = NSScreen.screens
        guard screens.indices.contains(screenIndex) else { return }
        requestSnapshot(screen: screens[screenIndex],
                        presetSelection: rect,
                        centeredImage: false,
                        generation: beginNewSession())
    }

    func autotestSeedAnnotations() {
        editorWindow?.seedTestAnnotations()
    }

    func autotestVerifyGeometry() -> String {
        editorWindow?.autotestVerifyGeometry() ?? "no-editor"
    }

    func autotestVerifySelectionResize() -> String {
        editorWindow?.autotestVerifySelectionResize() ?? "no-editor"
    }

    func autotestCopy() -> String {
        editorWindow?.autotestCopy() ?? "no-editor"
    }

    var hasEditor: Bool { editorWindow != nil }

    func autotestPin() -> String {
        editorWindow?.autotestPin() ?? "no-editor"
    }

    func autotestCancel() -> String {
        editorWindow?.autotestCancel() ?? "no-editor"
    }

    var pinnedCount: Int { pinController?.pinnedCount ?? -1 }
    var pinnedMemoryBytes: Int { pinController?.estimatedMemoryBytes ?? -1 }

    func autotestCloseAllPins() -> String {
        pinController?.autotestCloseAll() ?? "no-pin-controller"
    }

    func autotestHistoryWrite() -> String {
        guard let image = editorWindow?.exportedImage(), let historyStore else { return "no-editor-or-history" }
        historyStore.selfTestReset()
        switch historyStore.selfTestInsert(image) {
        case .success(let item):
            let exists = FileManager.default.fileExists(atPath: item.fileURL.path)
            return "items=\(historyStore.allItems.count) exists=\(exists) pixels=\(item.pixelWidth)x\(item.pixelHeight) bytes=\(item.byteCount)"
        case .failure(let error):
            return "write-failed \(error.localizedDescription)"
        }
    }

    func autotestHistoryClear() -> String {
        guard let historyStore else { return "no-history" }
        let cleared = historyStore.clearAll()
        return "cleared=\(cleared) remaining=\(historyStore.allItems.count) bytes=\(historyStore.totalBytes)"
    }

    func autotestToolbarOCR() -> String {
        editorWindow?.autotestExtractText() ?? "no-editor"
    }

    func autotestDumpOCRWindow(to path: String) -> String {
        editorWindow?.autotestDumpOCRWindow(to: path) ?? "no-editor"
    }

    func autotestOCRWindowCopy() -> String {
        editorWindow?.autotestOCRWindowCopy() ?? "no-editor"
    }

    func autotestShowEmptyOCRResult() -> String {
        editorWindow?.autotestShowEmptyOCRResult() ?? "no-editor"
    }

    func autotestCloseOCRWindow() -> String {
        editorWindow?.autotestCloseOCRWindow() ?? "no-editor"
    }

    func autotestHistoryOCR() -> String {
        guard let historyStore, let image = editorWindow?.exportedImage() else { return "no-editor-or-history" }
        let text = historyStore.selfTestRecognize(image)
        return "ocrChars=\(text.count)"
    }

    func autotestHistoryOCRIndex() -> String {
        guard let image = editorWindow?.exportedImage(), let historyStore else { return "no-editor-or-history" }
        historyStore.selfTestReset()
        guard case .success = historyStore.selfTestInsert(image) else { return "write-failed" }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, historyStore.ocrPendingCount > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let item = historyStore.allItems.first else { return "no-history-item" }
        let matches = historyStore.search(item.ocrText).count
        let result = "indexed=\(item.ocrIndexed) chars=\(item.ocrText.count) matches=\(matches)"
        _ = historyStore.clearAll()
        return result
    }

    /// 锚点用「窗口内相对位置」(0~1) 表达，避免按绝对坐标算出的锚点落在窗口之外，
    /// 那样「锚点不动」就失去验证意义了。
    func autotestZoom(factor: CGFloat, atRelative rx: CGFloat, _ ry: CGFloat) -> String {
        guard let frame = pinController?.autotestLastFrame else { return "no-pin-window" }
        let anchor = NSPoint(x: frame.minX + frame.width * rx, y: frame.minY + frame.height * ry)
        return pinController?.autotestZoomLast(factor: factor, at: anchor) ?? "no-pin-controller"
    }

    func showCaptureError(_ error: Error) {
        DispatchQueue.main.async {
            let nsError = error as NSError
            let bundleID = Bundle.main.bundleIdentifier ?? "未知"
            let path = Bundle.main.bundlePath
            let isScreenCaptureError = nsError.domain.contains("SCStream")
                || nsError.domain.contains("ScreenCapture")
                || nsError.localizedDescription.localizedCaseInsensitiveContains("permission")
            let hint = isScreenCaptureError
                ? "请确认系统设置中允许的是当前运行的 PinSnap：\n\(path)\n修改权限后请完全退出 PinSnap 再重新打开。"
                : "这不是权限提示，请把下面的错误域和错误码发给我。"
            let alert = NSAlert()
            alert.messageText = isScreenCaptureError ? "屏幕截图被系统拒绝" : "截图失败"
            alert.informativeText = "\(hint)\n\nBundle ID：\(bundleID)\n错误域：\(nsError.domain)\n错误码：\(nsError.code)\n详细信息：\(nsError.localizedDescription)"
            alert.addButton(withTitle: "打开屏幕录制设置")
            alert.addButton(withTitle: "关闭")
            if alert.runModal() == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
        }
    }
}

enum CGImageMini {
    static var placeholder: CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return context.makeImage()!
    }
}

final class WindowPickerPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private let windows: [SCWindow]
    private let completion: (SCWindow?) -> Void
    private let table = NSTableView()
    private weak var previousKeyWindow: NSWindow?

    init(windows: [SCWindow], completion: @escaping (SCWindow?) -> Void) {
        self.windows = windows
        self.completion = completion
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "选择要截取的窗口"
        level = .floating
        isReleasedWhenClosed = false
        center()

        let root = NSView()
        contentView = root
        let hint = NSTextField(wrappingLabelWithString: windows.isEmpty ? "没有发现可截图窗口。" : "双击窗口即可截取，截取后直接进入标注。")
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.title = "窗口"
        column.width = 560
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(confirm(_:))
        scroll.documentView = table

        let capture = NSButton(title: "截取窗口", target: self, action: #selector(confirm(_:)))
        capture.keyEquivalent = "\r"
        capture.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [NSView(), cancel, capture])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        root.addSubview(hint)
        root.addSubview(scroll)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            hint.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            buttons.heightAnchor.constraint(equalToConstant: 30)
        ])
        if !windows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    required init?(coder: NSCoder) { nil }

    func presentAsModalOverlay() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let title = windows[row].title?.isEmpty == false ? windows[row].title! : "未命名窗口"
        let app = windows[row].owningApplication?.applicationName ?? "未知应用"
        let text = "\(app)  —  \(title)"
        if cell.textField == nil {
            let label = NSTextField(labelWithString: text)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            cell.textField?.stringValue = text
        }
        return cell
    }

    @objc private func confirm(_ sender: Any?) {
        let row = table.selectedRow
        guard windows.indices.contains(row) else { NSSound.beep(); return }
        let selected = windows[row]
        let callback = completion
        orderOut(nil)
        callback(selected)
    }

    @objc private func cancel(_ sender: Any?) {
        let callback = completion
        orderOut(nil)
        callback(nil)
    }
}
