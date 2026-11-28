import Cocoa
import UniformTypeIdentifiers

final class CaptureEditorWindow: NSWindow {
    private let editor: CaptureEditView
    private let onClose: () -> Void

    init(snapshot: CaptureSnapshot,
         presetSelection: NSRect?,
         pinController: PinController?,
         historyStore: ScreenshotHistoryStore?,
         centeredImage: Bool = false,
         onClose: @escaping () -> Void) {
        self.onClose = onClose
        editor = CaptureEditView(snapshot: snapshot,
                                 presetSelection: presetSelection,
                                 pinController: pinController,
                                 historyStore: historyStore,
                                 centeredImage: centeredImage)
        super.init(contentRect: snapshot.screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(snapshot.screenFrame, display: true)
        // 关键：ARC 已经持有窗口。若 AppKit 在 close() 时再 release 一次，
        // 会在 autorelease pool drain 阶段出现 objc_release 过度释放并崩溃。
        isReleasedWhenClosed = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = editor
        editor.onFinish = { [weak self] in self?.finish() }
    }

    required init?(coder: NSCoder) { nil }
    override var canBecomeKey: Bool { true }

    // 全局快捷键触发后，应用可能仍处于非激活状态；保证覆盖层可立即成为 key window。
    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(editor)
    }

    func prepareForUserInput() {
        ignoresMouseEvents = false
        makeFirstResponder(editor)
    }

    func exportedImage() -> NSImage? { editor.renderSelection() }

    func exportedCGImage() -> CGImage? { editor.renderSelectionCGImage() }

    func dumpBaseImage(to path: String) -> String { editor.dumpBaseImage(to: path) }

    func dumpWholeView(to path: String) -> String { editor.dumpWholeView(to: path) }

    func seedTestAnnotations() { editor.seedTestAnnotations() }

    func autotestVerifyGeometry() -> String { editor.autotestVerifyGeometry() }

    func autotestVerifySelectionResize() -> String { editor.autotestVerifySelectionResize() }

    func autotestCopy() -> String {
        editor.copyForSelfTest()
        return "copy-ok"
    }

    func autotestExtractText() -> String { editor.autotestExtractText() }

    func autotestDumpOCRWindow(to path: String) -> String { editor.autotestDumpOCRWindow(to: path) }

    func autotestOCRWindowCopy() -> String { editor.autotestOCRWindowCopy() }

    func autotestShowEmptyOCRResult() -> String { editor.autotestShowEmptyOCRResult() }

    func autotestCloseOCRWindow() -> String { editor.autotestCloseOCRWindow() }

    func autotestPin() -> String {
        editor.pinForSelfTest()
        return "pin-ok"
    }

    func autotestCancel() -> String {
        editor.cancelForSelfTest()
        return "cancel-ok"
    }

    func autotestDumpToolbar(to path: String) -> String { editor.autotestDumpToolbar(to: path) }

    func autotestDumpPalette(text: Bool, to path: String) -> String { editor.autotestDumpPalette(text: text, to: path) }

    func autotestDumpEditorRegion(to path: String) -> String { editor.autotestDumpEditorRegion(to: path) }

    func applySnapshot(_ snapshot: CaptureSnapshot) { editor.applySnapshot(snapshot) }

    func autotestSimulateDrag() -> String { editor.autotestSimulateDrag() }

    var autotestPhaseName: String { editor.autotestPhaseName }

    func autotestPaletteStability() -> String { editor.autotestPaletteStability() }

    func dumpViewBitmap(to path: String) -> String { return editor.dumpSelectionView(to: path) }

    func closeSilently() {
        editor.closeOCRResultWindow()
        editor.detachTextInput()
        orderOut(nil)
        close()
    }

    private func finish() {
        // 保活到方法结束：onClose() 会清掉协调器对窗口的强引用。
        let strongSelf = self
        strongSelf.editor.closeOCRResultWindow()
        strongSelf.editor.detachTextInput()
        strongSelf.orderOut(nil)
        strongSelf.onClose()
        strongSelf.close()
    }
}

/// 参考图里的线性图标按钮：白底黑线、选中是蓝色圆角底、悬停是浅灰底。
private final class ToolbarButton: NSButton {
    enum Role {
        case tool
        case action
        case destructive
        case confirm
    }

    var role: Role = .action { didSet { refreshAppearance() } }
    var isActiveTool = false { didSet { refreshAppearance() } }
    private var isPointerInside = false { didSet { refreshAppearance() } }

    override var isEnabled: Bool { didSet { refreshAppearance() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }

    func refreshAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        guard isEnabled else {
            contentTintColor = NSColor.tertiaryLabelColor
            alphaValue = 0.55
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }

        alphaValue = 1
        // 选中态统一用中性浅灰，不再用蓝色块抢画布注意力。
        if isActiveTool {
            contentTintColor = .labelColor
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            return
        }

        switch role {
        case .destructive:
            contentTintColor = isPointerInside ? .systemRed : .labelColor
            layer?.backgroundColor = isPointerInside
                ? NSColor.systemRed.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
        case .confirm:
            contentTintColor = isPointerInside ? .systemGreen : .labelColor
            layer?.backgroundColor = isPointerInside
                ? NSColor.systemGreen.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
        default:
            contentTintColor = .labelColor
            layer?.backgroundColor = isPointerInside
                ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
                : NSColor.clear.cgColor
        }
    }
}

/// 参考图工具栏最左侧的六点拖拽把手。
private final class ToolbarGrip: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        for row in 0..<3 {
            for column in 0..<2 {
                let x = bounds.midX + (CGFloat(column) - 0.5) * 6 - 2
                let y = bounds.midY + (CGFloat(row) - 1) * 6 - 2
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2.5, height: 2.5)).fill()
            }
        }
    }
}

/// 统一的样式选择控件。它们不用系统按钮的默认 bezel，避免不同 macOS 版本
/// 把颜色、粗细按钮画成风格不一致的灰色小方块。
private class StyleChoiceButton: NSButton {
    var isSelected = false { didSet { needsDisplay = true } }
    private var isPointerInside = false { didSet { needsDisplay = true } }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }

    /// 选择态只保留一层很浅的灰色，不画高对比边框；靠控件本体表达选中。
    func drawSelectionBackground(in rect: NSRect, radius: CGFloat = 6) {
        if isSelected {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        } else if isPointerInside {
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }
}

private final class StyleSwatchButton: StyleChoiceButton {
    let swatchColor: NSColor

    init(color: NSColor, target: AnyObject?, action: Selector) {
        swatchColor = color
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        toolTip = "颜色"
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawSelectionBackground(in: bounds.insetBy(dx: 1, dy: 1), radius: 6)
        let diameter: CGFloat = 10
        let swatch = NSRect(x: bounds.midX - diameter / 2,
                            y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        swatchColor.setFill()
        NSBezierPath(ovalIn: swatch).fill()

        // 彩色圆点不描边；只有白点需要一圈浅灰边缘才能在白工具栏上看见。
        if swatchColor.isEqual(NSColor.white) {
            NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
            let edge = NSBezierPath(ovalIn: swatch.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
        }

        if isSelected {
            let ring = NSBezierPath(ovalIn: swatch.insetBy(dx: -1.8, dy: -1.8))
            ring.lineWidth = 1
            NSColor.labelColor.withAlphaComponent(0.30).setStroke()
            ring.stroke()
        }
    }
}

private final class StyleLineButton: StyleChoiceButton {
    let lineWidth: CGFloat

    init(lineWidth: CGFloat, target: AnyObject?, action: Selector) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        toolTip = "线宽 \(Int(lineWidth)) px"
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawSelectionBackground(in: bounds.insetBy(dx: 1, dy: 1), radius: 6)
        NSColor.labelColor.withAlphaComponent(isEnabled ? 0.78 : 0.22).setStroke()
        let path = NSBezierPath()
        path.lineWidth = min(max(lineWidth * 0.6, 1.2), 4)
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 8, y: bounds.midY))
        path.line(to: NSPoint(x: bounds.maxX - 8, y: bounds.midY))
        path.stroke()
    }
}

private final class StyleFontButton: StyleChoiceButton {
    let fontSize: CGFloat

    init(fontSize: CGFloat, target: AnyObject?, action: Selector) {
        self.fontSize = fontSize
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        toolTip = "字号 \(Int(fontSize)) pt"
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawSelectionBackground(in: bounds.insetBy(dx: 1, dy: 1), radius: 6)
        let primary = NSColor.labelColor.withAlphaComponent(isEnabled ? 0.90 : 0.24)
        let secondary = NSColor.labelColor.withAlphaComponent(isEnabled ? 0.55 : 0.18)
        let title = NSMutableAttributedString(string: "A", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: primary
        ])
        title.append(NSAttributedString(string: " \(Int(fontSize))", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: secondary
        ]))
        let size = title.size()
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                               y: bounds.midY - size.height / 2))
    }
}

final class CaptureEditView: NSView, NSTextFieldDelegate {
    var onFinish: (() -> Void)?

    private enum Phase { case selecting, editing }

    private enum SelectionHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var cursor: NSCursor {
            switch self {
            case .topLeft, .bottomRight: return .crosshair
            case .topRight, .bottomLeft: return .crosshair
            case .top, .bottom: return .resizeUpDown
            case .left, .right: return .resizeLeftRight
            }
        }
    }

    private let handleSize: CGFloat = 10
    private let minimumSelectionSize = NSSize(width: 8, height: 8)
    private var baseCGImage: CGImage
    private var baseDrawRect: NSRect
    private var scale: CGFloat
    private let pinController: PinController?
    private let historyStore: ScreenshotHistoryStore?
    private var phase: Phase
    private var selection: NSRect
    private var startPoint: NSPoint?
    private var resizingHandle: SelectionHandle?
    private var resizeInitialSelection: NSRect?
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var tool: AnnotationTool = .rectangle
    private var activePoints: [NSPoint] = []
    private var draftRect: NSRect?
    private var draftArrow: (start: NSPoint, end: NSPoint)?
    private var nextNumber = 1

    private func refreshNextNumber() {
        let used = Set(annotations.compactMap { annotation -> Int? in
            guard case .number(let value) = annotation.kind else { return nil }
            return value
        })
        var candidate = 1
        while used.contains(candidate) { candidate += 1 }
        nextNumber = candidate
    }
    private var sampler: PixelSampler?
    private var textField: NSTextField?
    /// 一个白色面板承载两行：主工具栏（短）+ 二级样式栏（居中、更窄）。
    private let toolbarPanel = NSView()
    private let toolbar = NSView()
    private let toolbarStack = NSStackView()
    private let styleStack = NSStackView()
    private let rowSeparator = NSView()
    private let inlineLineGroup = NSStackView()
    private let inlineColorGroup = NSStackView()
    private let inlineFontGroup = NSStackView()
    private var inlineColorButtons: [StyleSwatchButton] = []
    private var inlineLineButtons: [StyleLineButton] = []
    private var inlineFontButtons: [StyleFontButton] = []
    private var toolButtons: [ToolbarButton] = []
    /// 主栏只放工具和动作；样式放在下方二级栏，避免主栏被拉得很宽。
    private var toolbarBuilt = false
    // 色板顺序：红、橙、绿、蓝、黑、白。
    private let presetColors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .black, .white]
    private let presetLineWidths: [CGFloat] = [2, 4, 6]
    private let presetTextSizes: [CGFloat] = [18, 22, 28]
    private var annotationColor: NSColor = .systemRed
    // 默认值必须落在 presetLineWidths 里，否则面板三个圆点不会有任何选中态。
    private var annotationLineWidth: CGFloat = 4
    private var annotationTextFontSize: CGFloat = AnnotationRenderer.defaultTextFontSize
    private struct PendingTextStyle {
        let color: NSColor
        let fontSize: CGFloat
    }
    private var pendingTextStyle: PendingTextStyle?
    /// 复制、保存、固定最终只能完成一次：工具栏连点或 Return 重复触发时，
    /// 不应往本地历史写入多个完全相同的成品。
    private var isCompletingOutput = false
    /// OCR 是异步的，识别中禁止重复点击，避免多次写剪贴板。
    private var isExtractingText = false
    private var ocrResultWindow: OCRResultWindowController?
    private var notice: String?
    /// 底图还没回来时窗口保持全透明：让用户直接看到当前桌面，
    /// 而不是一块「铺了深色底 + 遮罩、但底下什么都没有」的黑屏。
    private var isPlaceholder = false
    /// 底图落位时暗化层从 0 淡入，避免整屏亮度硬跳变。
    private var dimProgress: CGFloat = 1
    private var dimTimer: Timer?

    init(snapshot: CaptureSnapshot, presetSelection: NSRect?, pinController: PinController?, historyStore: ScreenshotHistoryStore?, centeredImage: Bool = false) {
        self.pinController = pinController
        self.historyStore = historyStore
        baseCGImage = snapshot.image
        // 用 pointSize（pixelSize/scale）而不是 image.width：占位底图只有 1×1 像素，
        // 若按图片宽度反推，baseDrawRect 会缩成 1×1，选区 intersection 后直接被裁空。
        let pointSize = snapshot.pointSize
        isPlaceholder = snapshot.image.width <= 1 && snapshot.image.height <= 1
        if isPlaceholder { dimProgress = 0 }

        if centeredImage {
            let canvas = snapshot.screenFrame.size
            let origin = NSPoint(x: (canvas.width - pointSize.width) / 2,
                                 y: (canvas.height - pointSize.height) / 2)
            baseDrawRect = NSRect(origin: origin, size: pointSize)
        } else {
            baseDrawRect = NSRect(origin: .zero, size: pointSize)
        }
        scale = CGFloat(snapshot.image.width) / max(baseDrawRect.width, 1)

        if let presetSelection {
            selection = presetSelection
            phase = .editing
        } else if centeredImage {
            selection = baseDrawRect
            phase = .editing
        } else {
            selection = .zero
            phase = .selecting
        }
        super.init(frame: NSRect(origin: .zero, size: snapshot.screenFrame.size))
        wantsLayer = true
        // 工具栏只在编辑阶段才需要。区域截图先进入 selecting，此刻建它纯属拖慢首帧：
        // 十几个按钮 + SF Symbol + 约束一次要 50ms 上下，用户正是在等这一下。
        if phase == .editing {
            ensureToolbar()
            rebuildSampler()
            positionToolbar()
        }
        toolbarPanel.isHidden = phase == .selecting
        needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    // 全局快捷键触发后，应用可能仍处于非激活状态；让内容视图接收激活窗口的第一下点击。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
        updateLayerScales()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
        updateLayerScales()
        needsDisplay = true
    }

    /// 所有手写圆角/边框的 layer 都要按屏幕倍率栅格化，否则 Retina 上圆角是锯齿的。
    private func updateLayerScales() {
        let scale = window?.backingScaleFactor ?? 2
        toolbarPanel.layer?.contentsScale = scale
        toolButtons.forEach { $0.layer?.contentsScale = scale }
        inlineColorButtons.forEach { $0.layer?.contentsScale = scale }
        inlineLineButtons.forEach { $0.layer?.contentsScale = scale }
        inlineFontButtons.forEach { $0.layer?.contentsScale = scale }
    }

    override func resetCursorRects() {
        if phase == .selecting {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .arrow)
            for handle in SelectionHandle.allCases {
                addCursorRect(handleRect(handle), cursor: handle.cursor)
            }
        }
    }

    private func handleRect(_ handle: SelectionHandle) -> NSRect {
        let center = handleCenter(handle)
        return NSRect(x: center.x - handleSize / 2, y: center.y - handleSize / 2,
                      width: handleSize, height: handleSize)
    }

    private func handleCenter(_ handle: SelectionHandle) -> NSPoint {
        switch handle {
        case .topLeft: return NSPoint(x: selection.minX, y: selection.minY)
        case .top: return NSPoint(x: selection.midX, y: selection.minY)
        case .topRight: return NSPoint(x: selection.maxX, y: selection.minY)
        case .right: return NSPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight: return NSPoint(x: selection.maxX, y: selection.maxY)
        case .bottom: return NSPoint(x: selection.midX, y: selection.maxY)
        case .bottomLeft: return NSPoint(x: selection.minX, y: selection.maxY)
        case .left: return NSPoint(x: selection.minX, y: selection.midY)
        }
    }

    private func handleHitRect(_ handle: SelectionHandle) -> NSRect {
        handleRect(handle).insetBy(dx: -4, dy: -4)
    }

    private func handle(at point: NSPoint) -> SelectionHandle? {
        guard phase == .editing, !selection.isEmpty else { return nil }
        // Corners win over edge handles when their hit areas overlap.
        let handles: [SelectionHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft,
                                          .top, .right, .bottom, .left]
        return handles.first { handleHitRect($0).contains(point) }
    }

    private func ensureToolbar() {
        guard !toolbarBuilt else { return }
        toolbarBuilt = true
        buildToolbar()
        // 延迟构建的按钮也要按当前屏幕倍率栅格化，否则圆角在 Retina 上是锯齿。
        updateLayerScales()
    }

    private func buildToolbar() {
        // 白色面板只是一层底：无描边、无阴影，避免深色底图上出现一圈黑边。
        toolbarPanel.wantsLayer = true
        toolbarPanel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        toolbarPanel.layer?.contentsScale = window?.backingScaleFactor ?? 2
        toolbarPanel.layer?.cornerRadius = 11
        toolbarPanel.layer?.borderWidth = 0
        toolbarPanel.layer?.shadowOpacity = 0
        addSubview(toolbarPanel)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let stack = toolbarStack
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -5)
        ])

        for item in AnnotationTool.allCases {
            let button = toolbarButton(item.symbol,
                                       tooltip: item.title,
                                       action: #selector(selectTool(_:)),
                                       role: .tool)
            button.tag = item.rawValue
            toolButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(toolbarButton("text.viewfinder",
                                               tooltip: "提取截图文字（本机 OCR）",
                                               action: #selector(extractText(_:)),
                                               role: .action))
        stack.addArrangedSubview(separator())

        let undoButton = toolbarButton("arrow.uturn.backward", tooltip: "撤销（⌘Z）", action: #selector(undo(_:)), role: .action)
        let redoButton = toolbarButton("arrow.uturn.forward", tooltip: "重做（⇧⌘Z）", action: #selector(redo(_:)), role: .action)
        undoButton.identifier = NSUserInterfaceItemIdentifier("undo")
        redoButton.identifier = NSUserInterfaceItemIdentifier("redo")
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(toolbarButton("square.and.arrow.down", tooltip: "保存为 PNG（⌘S）", action: #selector(saveImage(_:)), role: .action))
        stack.addArrangedSubview(toolbarButton("pin", tooltip: "钉住到桌面", action: #selector(pinImage(_:)), role: .action))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(toolbarButton("xmark", tooltip: "取消（Esc）", action: #selector(cancel(_:)), role: .destructive))
        stack.addArrangedSubview(toolbarButton("checkmark", tooltip: "复制并退出（Return）", action: #selector(copyImage(_:)), role: .confirm))

        // 二级样式栏：比主栏窄，居中放在主栏下方。
        styleStack.orientation = .horizontal
        styleStack.alignment = .centerY
        styleStack.spacing = 1
        styleStack.translatesAutoresizingMaskIntoConstraints = false
        buildInlineStyleControls(into: styleStack)

        rowSeparator.wantsLayer = true
        rowSeparator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        rowSeparator.translatesAutoresizingMaskIntoConstraints = false

        toolbarPanel.addSubview(toolbar)
        toolbarPanel.addSubview(rowSeparator)
        toolbarPanel.addSubview(styleStack)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: toolbarPanel.topAnchor, constant: 5),
            toolbar.leadingAnchor.constraint(equalTo: toolbarPanel.leadingAnchor, constant: 7),
            toolbar.trailingAnchor.constraint(equalTo: toolbarPanel.trailingAnchor, constant: -7),
            toolbar.bottomAnchor.constraint(equalTo: rowSeparator.topAnchor, constant: -4),

            rowSeparator.leadingAnchor.constraint(equalTo: toolbarPanel.leadingAnchor, constant: 10),
            rowSeparator.trailingAnchor.constraint(equalTo: toolbarPanel.trailingAnchor, constant: -10),
            rowSeparator.heightAnchor.constraint(equalToConstant: 1),

            styleStack.centerXAnchor.constraint(equalTo: toolbarPanel.centerXAnchor),
            styleStack.topAnchor.constraint(equalTo: rowSeparator.bottomAnchor, constant: 3),
            styleStack.bottomAnchor.constraint(equalTo: toolbarPanel.bottomAnchor, constant: -5)
        ])

        refreshToolbarState()
    }

    private func buildInlineStyleControls(into stack: NSStackView) {
        func colorLabel(_ color: NSColor) -> String {
            let names = ["红", "橙", "绿", "蓝", "黑", "白"]
            return presetColors.firstIndex(where: { $0.isEqual(color) }).map { names[$0] } ?? "自定"
        }

        for group in [inlineLineGroup, inlineColorGroup, inlineFontGroup] {
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 1
            group.translatesAutoresizingMaskIntoConstraints = false
        }

        for (index, width) in presetLineWidths.enumerated() {
            let control = StyleLineButton(lineWidth: width, target: self, action: #selector(selectLineWidth(_:)))
            control.tag = index
            inlineLineButtons.append(control)
            inlineLineGroup.addArrangedSubview(control)
        }
        for (index, size) in presetTextSizes.enumerated() {
            let control = StyleFontButton(fontSize: size, target: self, action: #selector(selectFontSize(_:)))
            control.tag = index
            inlineFontButtons.append(control)
            inlineFontGroup.addArrangedSubview(control)
        }
        for (index, color) in presetColors.enumerated() {
            let control = StyleSwatchButton(color: color, target: self, action: #selector(selectColor(_:)))
            control.tag = index
            control.toolTip = "\(colorLabel(color))色"
            inlineColorButtons.append(control)
            inlineColorGroup.addArrangedSubview(control)
        }

        // 尺度组与颜色组之间留一条细分隔线；颜色始终可见。
        stack.addArrangedSubview(inlineLineGroup)
        stack.addArrangedSubview(inlineFontGroup)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(inlineColorGroup)
    }

    private func toolbarButton(_ symbol: String, tooltip: String, action: Selector, role: ToolbarButton.Role) -> ToolbarButton {
        let button = ToolbarButton()
        // 参考图是细线图标（约 16-17pt、regular 字重），不是加粗实心。
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: tooltip)
        button.image = baseImage?.withSymbolConfiguration(configuration)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.role = role
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.layer?.contentsScale = window?.backingScaleFactor ?? 2
        button.refreshAppearance()
        return button
    }

    private func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.30).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return view
    }

    private func refreshToolbarState() {
        for button in toolButtons {
            button.isActiveTool = button.tag == tool.rawValue
            button.refreshAppearance()
        }
        inlineLineGroup.isHidden = tool == .text
        inlineFontGroup.isHidden = tool != .text
        inlineColorGroup.isHidden = false
        for (index, button) in inlineColorButtons.enumerated() {
            button.isSelected = presetColors.indices.contains(index) && presetColors[index].isEqual(annotationColor)
        }
        for (index, button) in inlineLineButtons.enumerated() {
            button.isSelected = presetLineWidths.indices.contains(index) && presetLineWidths[index] == annotationLineWidth
        }
        for (index, button) in inlineFontButtons.enumerated() {
            button.isSelected = presetTextSizes.indices.contains(index) && presetTextSizes[index] == annotationTextFontSize
        }
        if let undoButton = toolbarStack.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: { $0.identifier?.rawValue == "undo" }) {
            undoButton.isEnabled = !annotations.isEmpty
        }
        if let redoButton = toolbarStack.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: { $0.identifier?.rawValue == "redo" }) {
            redoButton.isEnabled = !redoStack.isEmpty
        }
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard presetColors.indices.contains(sender.tag) else { return }
        annotationColor = presetColors[sender.tag]
        refreshToolbarState()
        needsDisplay = true
    }

    @objc private func selectLineWidth(_ sender: NSButton) {
        guard presetLineWidths.indices.contains(sender.tag) else { return }
        annotationLineWidth = presetLineWidths[sender.tag]
        refreshToolbarState()
        needsDisplay = true
    }

    @objc private func selectFontSize(_ sender: NSButton) {
        guard presetTextSizes.indices.contains(sender.tag) else { return }
        annotationTextFontSize = presetTextSizes[sender.tag]
        refreshToolbarState()
        needsDisplay = true
    }

    /// 工具栏 OCR：识别当前选区并打开结果窗口，不自动改写剪贴板。
    @objc private func extractText(_ sender: Any?) {
        guard !isExtractingText, let cgImage = renderSelectionCGImage() else { return }
        isExtractingText = true
        showNotice("正在识别文字…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self, cgImage] in
            let text = TextRecognitionService.recognizeText(in: cgImage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isExtractingText = false
                // 没识别到文字也要开窗：窗口里能明确告诉用户“识别完了，只是没有文字”，
                // 而不是丢一个 1.4 秒就消失的浮层，让人以为程序卡死。
                self.presentOCRResult(image: cgImage, text: text)
            }
        }
    }

    /// 打开本机 OCR 结果窗口。
    /// 编辑器是 `.screenSaver` 层级的全屏遮罩：先把它临时降到普通层级，
    /// 结果窗才能作为标准浮动窗口真正上屏；关窗时再恢复原层级。
    private func presentOCRResult(image: CGImage, text: String) {
        guard let editorWindow = window else { return }
        ocrResultWindow?.close()

        let controller = OCRResultWindowController(
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            text: text
        )
        let editorLevel = editorWindow.level
        editorWindow.level = .normal
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.ocrResultWindow === controller else { return }
            self.ocrResultWindow = nil
            self.window?.level = editorLevel
            // 回到截图编辑态，保留已有选区、标注和样式。
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.makeFirstResponder(self)
        }
        ocrResultWindow = controller
        controller.showAndActivate()
    }

    private func positionToolbar() {
        guard phase == .editing, !selection.isEmpty, !toolbarPanel.isHidden else { return }
        toolbarPanel.layoutSubtreeIfNeeded()
        let fit = toolbarPanel.fittingSize
        let width = ceil(fit.width)
        let height = ceil(fit.height)
        var y = selection.maxY + 8
        if y + height > bounds.height { y = selection.minY - height - 8 }
        if y < 0 { y = max(bounds.height - height - 8, 0) }
        let x = min(max(selection.midX - width / 2, 8), max(bounds.width - width - 8, 8))
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if toolbarPanel.frame != frame { toolbarPanel.frame = frame }
    }

    private func rebuildSampler() {
        guard !selection.isEmpty else { sampler = nil; return }
        guard let cropped = croppedImage(for: selection) else { sampler = nil; return }
        sampler = PixelSampler(image: cropped)
    }

    private func croppedImage(for rect: NSRect) -> CGImage? {
        let clipped = rect.intersection(baseDrawRect)
        guard clipped.width > 1, clipped.height > 1 else { return nil }
        let local = NSRect(x: clipped.minX - baseDrawRect.minX, y: clipped.minY - baseDrawRect.minY,
                           width: clipped.width, height: clipped.height)
        let pixelWidth = CGFloat(baseCGImage.width) / baseDrawRect.width
        let pixelHeight = CGFloat(baseCGImage.height) / baseDrawRect.height
        // 逐项取整而不是用 .integral：后者会向外扩张 0~1px，导致底图在导出时被拉伸重采样。
        let cropX = (local.minX * pixelWidth).rounded()
        let cropTop = (local.minY * pixelHeight).rounded()
        let cropW = max(1, (local.width * pixelWidth).rounded())
        let cropH = max(1, (local.height * pixelHeight).rounded())
        // CGImage.cropping(to:) 用的是「左上原点」，而 local.minY 本身就是从上往下量的距离，
        // 两者一致，不能再翻到底部原点——否则选区会被垂直错开 (H - 2y - h) 像素。
        let cropRect = CGRect(x: cropX, y: cropTop, width: cropW, height: cropH)
        let bounds = CGRect(x: 0, y: 0, width: baseCGImage.width, height: baseCGImage.height)
        let target = cropRect.intersection(bounds)
        guard target.width >= 1, target.height >= 1 else { return nil }
        return baseCGImage.cropping(to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 底图还在路上：窗口是 clear 的，这里一像素都不画，用户看到的就是实时桌面。
        // 旧实现在这里先铺 0.1 灰底再叠 35% 遮罩，占位图又是 1×1 透明图，
        // 于是按下快捷键的头一秒整屏是纯黑 —— 这就是「闪一下黑屏」的来源。
        guard !isPlaceholder else {
            drawSelectionChrome()
            return
        }

        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        bounds.fill()
        // 底图按原始像素落位：与窗口缩放一致时禁用插值，保证预览和导出一样锐利。
        let drawScale = CGFloat(baseCGImage.width) / max(baseDrawRect.width, 1)
        let viewScale = window?.backingScaleFactor ?? 1
        let baseQuality: CGInterpolationQuality = abs(drawScale - viewScale) < 0.01 ? .none : .high
        context.drawUprightCGImage(baseCGImage, in: baseDrawRect, quality: baseQuality)
        // 自测转储时按满值画，免得淡入中途转储导致选区边缘的抗锯齿像素不稳定。
        let dimAlpha = suppressChrome ? 1 : dimProgress

        if phase == .selecting {
            let dim = NSBezierPath(rect: bounds)
            if !selection.isEmpty { dim.append(NSBezierPath(rect: selection)) }
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.35 * dimAlpha).setFill()
            dim.fill()
            drawSelectionChrome()
            return
        }

        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: selection))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45 * dimAlpha).setFill()
        dim.fill()

        context.saveGState()
        let clip = selection.intersection(bounds)
        context.clip(to: clip)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, offset: .zero, sampler: sampler,
                                    samplerOrigin: selection.origin, scale: scale)
        }
        if let draftRect {
            let inset = annotationLineWidth / 2
            let rect = draftRect.insetBy(dx: inset, dy: inset).integral
            if rect.width > 0, rect.height > 0 {
                let path = NSBezierPath(roundedRect: rect,
                                        xRadius: min(4, rect.width / 5),
                                        yRadius: min(4, rect.height / 5))
                path.lineWidth = annotationLineWidth
                path.lineJoinStyle = .round
                annotationColor.setStroke()
                path.stroke()
            }
        }
        if let draftArrow {
            AnnotationRenderer.drawArrow(from: draftArrow.start, to: draftArrow.end,
                                         color: annotationColor,
                                         lineWidth: annotationLineWidth)
        }
        if activePoints.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = annotationLineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: activePoints[0])
            for point in activePoints.dropFirst() { path.line(to: point) }
            annotationColor.setStroke()
            path.stroke()
        }
        context.restoreGState()

        drawSelectionChrome()
        drawNotice()
    }

    /// 转储「净图」时置为 true：跳过描边、尺寸标签、把手等 UI 装饰，
    /// 否则它们会被算进选区内部，导致像素比对出现一圈假差异。
    private var suppressChrome = false

    private func drawSelectionChrome() {
        guard !selection.isEmpty, !suppressChrome else { return }
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()

        NSColor.systemBlue.setFill()
        for handle in SelectionHandle.allCases {
            let rect = handleRect(handle)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }

        let label = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        var box = NSRect(x: selection.minX, y: selection.minY - size.height - 8, width: size.width + 12, height: size.height + 6)
        if box.minY < 0 { box.origin.y = selection.minY + 6 }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(in: box.insetBy(dx: 6, dy: 3), withAttributes: attributes)

        if phase == .selecting {
            let hint = "拖动选择区域，按 Esc 取消"
            let hintAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let hintSize = hint.size(withAttributes: hintAttributes)
            let hintBox = NSRect(x: bounds.midX - hintSize.width / 2 - 14, y: 32, width: hintSize.width + 28, height: hintSize.height + 14)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: hintBox, xRadius: 7, yRadius: 7).fill()
            hint.draw(at: NSPoint(x: hintBox.minX + 14, y: hintBox.minY + 7), withAttributes: hintAttributes)
        }
    }

    private func drawNotice() {
        guard let notice, !suppressChrome else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = notice.size(withAttributes: attributes)
        let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: 70, width: size.width + 32, height: size.height + 14)
        NSColor.systemGreen.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        notice.draw(at: NSPoint(x: box.minX + 16, y: box.minY + 7), withAttributes: attributes)
    }

    private func showNotice(_ text: String) {
        notice = text
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.notice = nil
            self?.needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if phase == .selecting {
            startPoint = point
            selection = NSRect(origin: point, size: .zero)
            needsDisplay = true
            return
        }
        if let handle = handle(at: point) {
            resizingHandle = handle
            resizeInitialSelection = selection
            startPoint = point
            return
        }
        guard selection.contains(point) else { return }
        if let textField {
            commitText(textField)
        }
        switch tool {
        case .pen:
            activePoints = [point]
        case .number:
            annotations.append(Annotation(kind: .number(nextNumber), start: point, end: point,
                                          points: [], color: annotationColor, lineWidth: 0))
            nextNumber += 1
            redoStack.removeAll()
            needsDisplay = true
        case .text:
            presentTextField(at: point)
        case .rectangle, .mosaic:
            startPoint = point
            draftRect = NSRect(origin: point, size: .zero)
        case .arrow:
            startPoint = point
            draftArrow = (point, point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if phase == .selecting {
            guard let startPoint else { return }
            selection = NSRect(x: min(startPoint.x, point.x), y: min(startPoint.y, point.y),
                               width: abs(point.x - startPoint.x), height: abs(point.y - startPoint.y))
            needsDisplay = true
            return
        }
        if let resizingHandle, let resizeInitialSelection {
            selection = resizedSelection(from: resizeInitialSelection, handle: resizingHandle, to: point)
            positionToolbar()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        switch tool {
        case .pen:
            guard !activePoints.isEmpty else { return }
            activePoints.append(point)
            needsDisplay = true
        case .rectangle, .mosaic:
            guard let startPoint else { return }
            draftRect = NSRect(x: min(startPoint.x, point.x), y: min(startPoint.y, point.y),
                               width: abs(point.x - startPoint.x), height: abs(point.y - startPoint.y))
            needsDisplay = true
        case .arrow:
            guard let startPoint else { return }
            draftArrow = (startPoint, point)
            needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if phase == .selecting {
            startPoint = nil
            guard selection.width >= 8, selection.height >= 8 else {
                selection = .zero
                needsDisplay = true
                return
            }
            selection = selection.intersection(baseDrawRect)
            guard !selection.isEmpty else { return }
            enterEditing()
            return
        }
        if resizingHandle != nil {
            resizingHandle = nil
            resizeInitialSelection = nil
            startPoint = nil
            rebuildSampler()
            positionToolbar()
            needsDisplay = true
            return
        }
        switch tool {
        case .pen:
            if activePoints.count > 1 {
                annotations.append(Annotation(kind: .pen, start: activePoints[0], end: point,
                                              points: activePoints, color: annotationColor,
                                              lineWidth: annotationLineWidth))
                redoStack.removeAll()
            }
            activePoints = []
        case .rectangle, .mosaic:
            if let rect = draftRect, rect.width > 3, rect.height > 3 {
                annotations.append(Annotation(kind: tool == .rectangle ? .rectangle : .mosaic,
                                              start: rect.origin,
                                              end: NSPoint(x: rect.maxX, y: rect.maxY),
                                              points: [], color: annotationColor,
                                              lineWidth: tool == .mosaic ? 0 : annotationLineWidth))
                redoStack.removeAll()
            }
            draftRect = nil
            startPoint = nil
        case .arrow:
            if let arrow = draftArrow, hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y) > 6 {
                annotations.append(Annotation(kind: .arrow, start: arrow.start, end: arrow.end,
                                              points: [], color: annotationColor,
                                              lineWidth: annotationLineWidth))
                redoStack.removeAll()
            }
            draftArrow = nil
            startPoint = nil
        default:
            break
        }
        needsDisplay = true
    }

    private func enterEditing() {
        phase = .editing
        ensureToolbar()
        toolbarPanel.isHidden = false
        rebuildSampler()
        positionToolbar()
        needsLayout = true
        needsDisplay = true
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    private func resizedSelection(from initial: NSRect, handle: SelectionHandle, to point: NSPoint) -> NSRect {
        let point = NSPoint(x: min(max(point.x, baseDrawRect.minX), baseDrawRect.maxX),
                            y: min(max(point.y, baseDrawRect.minY), baseDrawRect.maxY))
        var minX = initial.minX, maxX = initial.maxX
        var minY = initial.minY, maxY = initial.maxY
        switch handle {
        case .topLeft:
            minX = min(point.x, maxX - minimumSelectionSize.width)
            minY = min(point.y, maxY - minimumSelectionSize.height)
        case .top:
            minY = min(point.y, maxY - minimumSelectionSize.height)
        case .topRight:
            maxX = max(point.x, minX + minimumSelectionSize.width)
            minY = min(point.y, maxY - minimumSelectionSize.height)
        case .right:
            maxX = max(point.x, minX + minimumSelectionSize.width)
        case .bottomRight:
            maxX = max(point.x, minX + minimumSelectionSize.width)
            maxY = max(point.y, minY + minimumSelectionSize.height)
        case .bottom:
            maxY = max(point.y, minY + minimumSelectionSize.height)
        case .bottomLeft:
            minX = min(point.x, maxX - minimumSelectionSize.width)
            maxY = max(point.y, minY + minimumSelectionSize.height)
        case .left:
            minX = min(point.x, maxX - minimumSelectionSize.width)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func presentTextField(at point: NSPoint) {
        let style = PendingTextStyle(color: annotationColor, fontSize: annotationTextFontSize)
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - style.fontSize * 0.64,
                                              width: 220, height: style.fontSize + 10))
        field.font = .systemFont(ofSize: style.fontSize, weight: .semibold)
        field.textColor = style.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        field.delegate = self
        pendingTextStyle = style
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) { commitText(sender) }

    private func commitText(_ field: NSTextField) {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let origin = textField?.frame.origin else { return }
        let style = pendingTextStyle ?? PendingTextStyle(color: annotationColor, fontSize: annotationTextFontSize)
        if !value.isEmpty {
            annotations.append(Annotation(kind: .text(value), start: NSPoint(x: origin.x, y: origin.y),
                                          end: NSPoint(x: origin.x, y: origin.y + style.fontSize),
                                          points: [], color: style.color, lineWidth: 0,
                                          textFontSize: style.fontSize))
            redoStack.removeAll()
        }
        field.removeFromSuperview()
        textField = nil
        pendingTextStyle = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textView.string = ""
            if let textField {
                self.textField = nil
                pendingTextStyle = nil
                textField.removeFromSuperview()
            }
            window?.makeFirstResponder(self)
            needsDisplay = true
            return true
        }
        return false
    }

    /// 点击仅切换工具。样式控件直接固定在同一条工具栏上，不再弹出第二层面板。
    @objc private func selectTool(_ sender: NSButton) {
        guard let selected = AnnotationTool(rawValue: sender.tag) else { return }
        tool = selected
        refreshToolbarState()
        positionToolbar()
    }

    @objc private func undo(_ sender: Any?) {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        refreshNextNumber()
        refreshToolbarState()
        needsDisplay = true
    }

    @objc private func redo(_ sender: Any?) {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
        refreshNextNumber()
        refreshToolbarState()
        needsDisplay = true
    }

    @objc private func cancel(_ sender: Any?) { finish() }

    @objc private func copyImage(_ sender: Any?) {
        guard !isCompletingOutput, let image = renderSelection() else { return }
        isCompletingOutput = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        historyStore?.add(image)
        showNotice("已复制到剪贴板")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.finish() }
    }

    @objc private func saveImage(_ sender: Any?) {
        guard !isCompletingOutput, let cgImage = renderSelectionCGImage(), let window else { return }
        isCompletingOutput = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PinSnap-\(Int(Date().timeIntervalSince1970)).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                self?.isCompletingOutput = false
                return
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                self?.isCompletingOutput = false
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                self?.historyStore?.add(NSImage(cgImage: cgImage,
                                                 size: NSSize(width: CGFloat(cgImage.width),
                                                              height: CGFloat(cgImage.height))))
                self?.showNotice("已保存")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self?.finish() }
            } catch {
                self?.isCompletingOutput = false
                self?.showSaveError(error)
            }
        }
    }

    private func showSaveError(_ error: Error) {
        let nsError = error as NSError
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法保存 PNG"
        alert.informativeText = "请确认目标文件夹可写且磁盘空间充足。\n\n错误：\(nsError.localizedDescription)"
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func pinImage(_ sender: Any?) {
        guard !isCompletingOutput, let image = renderSelection() else { return }
        isCompletingOutput = true
        // 固定到截图所在的那块屏幕，而不是「当前主屏」。
        historyStore?.add(image)
        let evicted = pinController?.pin(image, on: window?.screen) ?? 0
        if evicted > 0 {
            showNotice("已固定；为控制内存已关闭最早的 \(evicted) 张")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finish() }
        } else {
            finish()
        }
    }

    private func finish() {
        textField?.removeFromSuperview()
        textField = nil
        pendingTextStyle = nil
        onFinish?()
    }

    func detachTextInput() {
        textField?.removeFromSuperview()
        textField = nil
        pendingTextStyle = nil
    }

    /// 编辑器整体关闭（新截图顶替、取消、完成）时，结果窗不能留在屏幕上。
    /// 先断开引用再 close，让 onClose 里的“恢复编辑器”逻辑自动跳过。
    func closeOCRResultWindow() {
        guard let controller = ocrResultWindow else { return }
        ocrResultWindow = nil
        controller.close()
    }

    /// 自测：模拟一次完整拖拽（按下→拖动→松开），验证遮罩一出现就能画框。
    func autotestSimulateDrag(from start: NSPoint = NSPoint(x: 300, y: 300),
                              to end: NSPoint = NSPoint(x: 800, y: 700)) -> String {
        let wasSelecting = phase == .selecting
        guard let down = fakeMouseEvent(.leftMouseDown, at: start),
              let dragged = fakeMouseEvent(.leftMouseDragged, at: end),
              let up = fakeMouseEvent(.leftMouseUp, at: end) else {
            return "event-create-failed"
        }
        mouseDown(with: down)
        mouseDragged(with: dragged)
        mouseUp(with: up)
        let editing = phase == .editing
        return "startSelecting=\(wasSelecting) editing=\(editing) selection=\(Int(selection.width))x\(Int(selection.height))"
    }

    /// 自测：报告当前处于哪个阶段（selecting 是否已就绪）。
    var autotestPhaseName: String {
        switch phase {
        case .selecting: return "selecting"
        case .editing: return "editing"
        }
    }

    private func fakeMouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type,
                           location: convert(point, to: nil),
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.windowNumber ?? 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 1,
                           pressure: 1)
    }

    /// 自测：样式内嵌后，切换颜色不应改变工具栏尺寸或位置。
    func autotestPaletteStability() -> String {
        guard phase == .editing else { return "no-editor" }
        tool = .rectangle
        refreshToolbarState()
        toolbarPanel.layoutSubtreeIfNeeded()
        let frameBefore = toolbarPanel.frame
        if inlineColorButtons.indices.contains(2) {
            selectColor(inlineColorButtons[2])
        }
        toolbarPanel.layoutSubtreeIfNeeded()
        let frameAfter = toolbarPanel.frame
        let dx = abs(frameBefore.minX - frameAfter.minX)
        let dy = abs(frameBefore.minY - frameAfter.minY)
        return "inline=true sameFrame=\(frameBefore == frameAfter) "
            + "posDelta=(\(Int(dx)),\(Int(dy))) stable=\(frameBefore == frameAfter && dx < 0.5 && dy < 0.5)"
    }

    /// 自测：把工具栏视图离屏渲染成 PNG，用于无截屏环境下的视觉回归。
    func autotestDumpToolbar(to path: String) -> String {
        guard phase == .editing else { return "no-editor" }
        toolbarPanel.layoutSubtreeIfNeeded()
        let size = toolbarPanel.bounds.size
        guard size.width > 1, size.height > 1 else { return "empty-toolbar" }
        let rect = NSRect(origin: .zero, size: size)
        guard let rep = toolbarPanel.bitmapImageRepForCachingDisplay(in: rect) else { return "no-rep" }
        toolbarPanel.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "toolbar=\(Int(size.width))x\(Int(size.height))"
    }

    /// 自测：样式已内嵌工具栏，直接渲染整条工具栏作为视觉回归图。
    func autotestDumpPalette(text: Bool, to path: String) -> String {
        guard phase == .editing else { return "no-editor" }
        let previousTool = tool
        tool = text ? .text : .rectangle
        refreshToolbarState()
        defer {
            tool = previousTool
            refreshToolbarState()
        }
        toolbarPanel.layoutSubtreeIfNeeded()
        let size = toolbarPanel.bounds.size
        guard size.width > 1, size.height > 1 else { return "empty-toolbar" }
        let rect = NSRect(origin: .zero, size: size)
        guard let rep = toolbarPanel.bitmapImageRepForCachingDisplay(in: rect) else { return "no-rep" }
        toolbarPanel.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "inline=\(Int(size.width))x\(Int(size.height))"
    }

    /// 自测：渲染「选区 + 标注 + 工具栏」整体区域，验证所见即所得。
    func autotestDumpEditorRegion(to path: String) -> String {
        guard phase == .editing, !selection.isEmpty else { return "no-editor" }
        toolbarPanel.layoutSubtreeIfNeeded()
        var region = selection.insetBy(dx: -50, dy: -50)
        region.size.height += 130 + toolbarPanel.bounds.height
        region = region.intersection(bounds)
        guard region.width > 1, region.height > 1 else { return "empty-region" }
        guard let rep = bitmapImageRepForCachingDisplay(in: region) else { return "no-rep" }
        cacheDisplay(in: region, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "editor=\(Int(region.width))x\(Int(region.height))"
    }

    /// 抓图晚于遮罩出现：底图到手后原地填充，不重建窗口，用户正在拖的选区不受影响。
    func applySnapshot(_ snapshot: CaptureSnapshot) {
        baseCGImage = snapshot.image
        let pointSize = snapshot.pointSize
        baseDrawRect = NSRect(origin: .zero, size: pointSize)
        scale = CGFloat(snapshot.image.width) / max(baseDrawRect.width, 1)
        let wasPlaceholder = isPlaceholder
        isPlaceholder = false
        rebuildSampler()
        if wasPlaceholder {
            // 从「透明穿透的实时桌面」切到「底图 + 暗化层」：暗化层淡入，
            // 底图本身是同一帧画面，视觉上只有一次轻微的调暗，不再有黑屏闪跳。
            dimProgress = 0
            animateDimIn()
        }
        needsDisplay = true
    }

    private func animateDimIn() {
        dimTimer?.invalidate()
        let started = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.12
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - started) / duration)
            self.dimProgress = CGFloat(progress)
            self.needsDisplay = true
            if progress >= 1 {
                timer.invalidate()
                self.dimTimer = nil
            }
        }
        // .common：拖拽追踪开始后 default mode 会被挂起，动画必须照样跑完。
        RunLoop.main.add(timer, forMode: .common)
        dimTimer = timer
    }

    deinit {
        dimTimer?.invalidate()
    }

    func dumpBaseImage(to path: String) -> String {
        let rep = NSBitmapImageRep(cgImage: baseCGImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "base=\(baseCGImage.width)x\(baseCGImage.height) selection=\(selection)"
    }

    /// 整视图转储 + 平均 alpha 采样。
    /// 专门用来验证「占位期不画黑」：占位时窗口应当几乎全透明（alpha≈0，透出实时桌面），
    /// 底图落位后应当接近不透明。旧实现在占位期铺满深色底，alpha 会直接顶到 255。
    func dumpWholeView(to path: String) -> String {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return "no-rep" }
        cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))

        var alphaSum: CGFloat = 0
        var samples = 0
        let count = 400
        for index in 0..<count {
            let x = (index * 37 + 11) % max(rep.pixelsWide, 1)
            let y = (index * 71 + 7) % max(rep.pixelsHigh, 1)
            if let color = rep.colorAt(x: x, y: y) {
                alphaSum += color.alphaComponent
                samples += 1
            }
        }
        let avg = samples > 0 ? Int((alphaSum / CGFloat(samples)) * 255) : -1
        return "view=\(rep.pixelsWide)x\(rep.pixelsHigh) alpha=\(avg) placeholder=\(isPlaceholder) path=\(path)"
    }

    /// 只转储“用户实际看到的选区画面”（不含工具栏、遮罩、边框），
    /// 用于和导出图做像素级比对，验证「所见」与「所得」是否一致。
    func dumpSelectionView(to path: String) -> String {
        guard !selection.isEmpty else { return "no-selection" }
        let wasHidden = toolbarPanel.isHidden
        toolbarPanel.isHidden = true
        suppressChrome = true
        defer {
            toolbarPanel.isHidden = wasHidden
            suppressChrome = false
        }

        let rect = selection
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return "no-rep" }
        cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "viewsel=\(rep.pixelsWide)x\(rep.pixelsHigh) rect=\(rect)"
    }

    /// 自证：内部裁剪结果必须与「由选区独立换算出的像素矩形」逐像素一致。
    /// 这条断言专门防住「框选位置与导出位置错开」这类几何回归。
    func autotestVerifyGeometry() -> String {
        guard !selection.isEmpty else { return "no-selection" }
        let sx = CGFloat(baseCGImage.width) / baseDrawRect.width
        let sy = CGFloat(baseCGImage.height) / baseDrawRect.height
        // 选区在底图中的偏移（视图已翻转，minY 即从上往下的距离）
        let localX = (selection.minX - baseDrawRect.origin.x) * sx
        let localY = (selection.minY - baseDrawRect.origin.y) * sy
        let expect = CGRect(x: localX.rounded(), y: localY.rounded(),
                            width: (selection.width * sx).rounded(),
                            height: (selection.height * sy).rounded())
        guard let got = croppedImage(for: selection) else { return "FAIL 内部裁剪返回 nil" }
        guard let ref = baseCGImage.cropping(to: expect) else { return "FAIL 参考裁剪失败" }
        guard got.width == ref.width, got.height == ref.height else {
            return "FAIL 尺寸不符 got=\(got.width)x\(got.height) expect=\(ref.width)x\(ref.height) rect=\(expect)"
        }
        let diff = Self.averagePixelDiff(got, ref)
        let verdict = diff.max <= 1 ? "PASS" : "FAIL"
        return String(format: "%@ 裁剪原点应为(%.0f,%.0f) 平均差=%.3f 最大差=%d",
                      verdict, expect.minX, expect.minY, diff.avg, diff.max)
    }

    /// 回归选区八个把手：验证每个方向都受最小尺寸和底图边界约束。
    func autotestVerifySelectionResize() -> String {
        guard phase == .editing, !selection.isEmpty else { return "no-selection" }
        let original = selection
        defer { selection = original; positionToolbar(); needsDisplay = true }
        let checks: [(SelectionHandle, NSPoint)] = [
            (.topLeft, NSPoint(x: baseDrawRect.minX - 80, y: baseDrawRect.minY - 80)),
            (.top, NSPoint(x: original.midX, y: baseDrawRect.minY - 80)),
            (.topRight, NSPoint(x: baseDrawRect.maxX + 80, y: baseDrawRect.minY - 80)),
            (.right, NSPoint(x: baseDrawRect.maxX + 80, y: original.midY)),
            (.bottomRight, NSPoint(x: baseDrawRect.maxX + 80, y: baseDrawRect.maxY + 80)),
            (.bottom, NSPoint(x: original.midX, y: baseDrawRect.maxY + 80)),
            (.bottomLeft, NSPoint(x: baseDrawRect.minX - 80, y: baseDrawRect.maxY + 80)),
            (.left, NSPoint(x: baseDrawRect.minX - 80, y: original.midY))
        ]
        for (handle, point) in checks {
            let resized = resizedSelection(from: original, handle: handle, to: point)
            guard baseDrawRect.contains(resized),
                  resized.width >= minimumSelectionSize.width,
                  resized.height >= minimumSelectionSize.height else {
                return "FAIL \(handle) result=\(resized) base=\(baseDrawRect)"
            }
        }
        return "PASS 八向选区调整边界与最小尺寸"
    }

    /// 两张同尺寸位图的逐像素最大通道差
    static func averagePixelDiff(_ a: CGImage, _ b: CGImage) -> (avg: Double, max: Int) {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        guard w > 0, h > 0 else { return (999, 999) }
        func render(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return buf }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let pa = render(a), pb = render(b)
        var sum = 0.0, mx = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            for c in 0..<3 {
                let d = abs(Int(pa[i + c]) - Int(pb[i + c]))
                sum += Double(d)
                if d > mx { mx = d }
            }
        }
        return (sum / Double(w * h * 3), mx)
    }

    func copyForSelfTest() {
        copyImage(nil)
    }

    /// 自测 OCR：走真实的“点击 → 识别 → 开窗”路径，不触碰剪贴板。
    /// 不再返回写死的成功字符串——窗口没出现就必须暴露出来。
    func autotestExtractText() -> String {
        guard let cgImage = renderSelectionCGImage() else { return "no-image" }
        let pasteboardBefore = NSPasteboard.general.changeCount
        let started = CACurrentMediaTime()
        let text = TextRecognitionService.recognizeText(in: cgImage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = Int((CACurrentMediaTime() - started) * 1000)
        presentOCRResult(image: cgImage, text: text)
        guard let ocrWindow = ocrResultWindow?.window else {
            return "chars=\(text.count) window=missing"
        }
        let aboveEditor = ocrWindow.level.rawValue > (window?.level.rawValue ?? 0)
        let pasteboardUntouched = NSPasteboard.general.changeCount == pasteboardBefore
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        // 真实截图里的中文也必须认出来，否则又回到“全英文乱码”的老问题。
        let preview = String(text.prefix(24)).replacingOccurrences(of: "\n", with: " / ")
        return "chars=\(text.count) cjk=\(cjk) ms=\(elapsed) window=true visible=\(ocrWindow.isVisible) "
            + "key=\(ocrWindow.isKeyWindow) level=\(ocrWindow.level.rawValue) "
            + "editorLevel=\(window?.level.rawValue ?? -1) "
            + "aboveEditor=\(aboveEditor) clipboardUntouched=\(pasteboardUntouched) "
            + "preview=\(preview)"
    }

    func autotestDumpOCRWindow(to path: String) -> String {
        guard let controller = ocrResultWindow else { return "no-window" }
        return controller.autotestDump(to: path, editorWindow: window)
    }

    func autotestOCRWindowCopy() -> String {
        ocrResultWindow?.autotestCopyChecks() ?? "no-window"
    }

    /// 自测“识别不到文字”的结果窗：不能只弹一个会消失的提示。
    func autotestShowEmptyOCRResult() -> String {
        guard let cgImage = renderSelectionCGImage() else { return "no-image" }
        presentOCRResult(image: cgImage, text: "")
        guard let ocrWindow = ocrResultWindow?.window else { return "window=missing" }
        return "visible=\(ocrWindow.isVisible) key=\(ocrWindow.isKeyWindow) empty=true"
    }

    /// 关闭结果窗后，截图编辑器必须恢复原层级并重新拿到焦点，
    /// 否则后面的标注、保存、Pin 全会落在错误的窗口状态上。
    func autotestCloseOCRWindow() -> String {
        guard let controller = ocrResultWindow else { return "no-window" }
        controller.close()
        let editorKey = window?.isKeyWindow ?? false
        let levelRestored = window?.level == .screenSaver
        return "closed=true released=\(ocrResultWindow == nil) "
            + "editorPresent=\(window?.isVisible ?? false) editorKey=\(editorKey) levelRestored=\(levelRestored)"
    }

    func pinForSelfTest() {
        pinImage(nil)
    }

    func cancelForSelfTest() {
        cancel(nil)
    }

    func seedTestAnnotations() {
        guard !selection.isEmpty else { return }
        let origin = NSPoint(x: selection.minX + 40, y: selection.minY + 40)
        annotations.append(Annotation(kind: .rectangle,
                                      start: origin,
                                      end: NSPoint(x: origin.x + 160, y: origin.y + 90),
                                      points: [], color: .systemRed, lineWidth: 3))
        annotations.append(Annotation(kind: .number(1),
                                      start: NSPoint(x: origin.x + 40, y: origin.y + 130),
                                      end: .zero, points: [], color: .systemBlue, lineWidth: 0))
        var points: [NSPoint] = []
        for index in 0..<40 {
            points.append(NSPoint(x: origin.x + 210 + CGFloat(index) * 4,
                                  y: origin.y + 40 + sin(CGFloat(index) / 5) * 20))
        }
        annotations.append(Annotation(kind: .pen, start: points[0], end: points[points.count - 1],
                                      points: points, color: .systemGreen, lineWidth: 3))
        annotations.append(Annotation(kind: .text("PinSnap 文字标注"),
                                      start: NSPoint(x: origin.x, y: origin.y + 165),
                                      end: .zero, points: [], color: .systemRed, lineWidth: 0))
        annotations.append(Annotation(kind: .mosaic,
                                      start: NSPoint(x: origin.x + 320, y: origin.y + 100),
                                      end: NSPoint(x: origin.x + 520, y: origin.y + 220),
                                      points: [], color: .black, lineWidth: 0))
        annotations.append(Annotation(kind: .arrow,
                                      start: NSPoint(x: origin.x + 210, y: origin.y + 165),
                                      end: NSPoint(x: origin.x + 420, y: origin.y + 265),
                                      points: [], color: .systemRed, lineWidth: 3))
        needsDisplay = true
    }

    func renderSelection() -> NSImage? {
        guard let cgImage = renderSelectionCGImage() else { return nil }
        return NSImage(cgImage: cgImage, size: selection.size)
    }

    /// 直接产出 CGImage：保存时不再绕 NSImage → TIFF，避免多一次色彩空间转换。
    func renderSelectionCGImage() -> CGImage? {
        guard !selection.isEmpty, let cropped = croppedImage(for: selection) else { return nil }
        let size = selection.size
        // 用裁剪出的真实像素建立画布，底图正好铺满 → 1:1，不会被缩放插值。
        let pixelWidth = cropped.width
        let pixelHeight = cropped.height
        // 沿用源图色彩空间，避免二次色彩转换造成偏色。
        let colorSpace = cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(data: nil,
                                 width: pixelWidth,
                                 height: pixelHeight,
                                 bitsPerComponent: 8,
                                 bytesPerRow: 0,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // 画布像素比点尺寸略大/略小时的等效缩放，用于对齐标注坐标。
        let renderScale = CGFloat(pixelWidth) / max(size.width, 1)
        let renderScaleY = CGFloat(pixelHeight) / max(size.height, 1)

        // 关键：位图上下文的用户空间是「像素」。先把 CTM 放大到点坐标系，
        // 再翻转成左上原点；否则 Retina 上内容只会画进左下角 1/4 区域。
        cg.scaleBy(x: renderScale, y: renderScaleY)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        cg.drawUprightCGImage(cropped, in: CGRect(origin: .zero, size: size), quality: .none)
        let localSampler = PixelSampler(image: cropped)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation,
                                    offset: NSPoint(x: -selection.minX, y: -selection.minY),
                                    sampler: localSampler,
                                    samplerOrigin: selection.origin,
                                    scale: renderScale)
        }
        NSGraphicsContext.restoreGraphicsState()

        return cg.makeImage()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            finish()
        case 36, 76:
            copyImage(nil)
        case 6:
            if event.modifierFlags.contains(.command) {
                event.modifierFlags.contains(.shift) ? redo(nil) : undo(nil)
            } else {
                super.keyDown(with: event)
            }
        case 1:
            if event.modifierFlags.contains(.command) { saveImage(nil) } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }
}
