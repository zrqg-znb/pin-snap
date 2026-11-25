import Cocoa
import UniformTypeIdentifiers

final class CaptureEditorWindow: NSWindow {
    private let editor: CaptureEditView
    private let onClose: () -> Void

    init(snapshot: CaptureSnapshot,
         presetSelection: NSRect?,
         pinController: PinController?,
         centeredImage: Bool = false,
         onClose: @escaping () -> Void) {
        self.onClose = onClose
        editor = CaptureEditView(snapshot: snapshot,
                                 presetSelection: presetSelection,
                                 pinController: pinController,
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

    func seedTestAnnotations() { editor.seedTestAnnotations() }

    func autotestVerifyGeometry() -> String { editor.autotestVerifyGeometry() }

    func autotestVerifySelectionResize() -> String { editor.autotestVerifySelectionResize() }

    func autotestCopy() -> String {
        editor.copyForSelfTest()
        return "copy-ok"
    }

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

    private func finish() {
        // 保活到方法结束：onClose() 会清掉协调器对窗口的强引用。
        let strongSelf = self
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
        if isActiveTool {
            contentTintColor = .controlAccentColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            return
        }

        switch role {
        case .destructive:
            contentTintColor = .systemRed
            layer?.backgroundColor = isPointerInside
                ? NSColor.systemRed.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        case .confirm:
            contentTintColor = .systemGreen
            layer?.backgroundColor = isPointerInside
                ? NSColor.systemGreen.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        default:
            contentTintColor = .labelColor
            layer?.backgroundColor = isPointerInside
                ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
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
    private var sampler: PixelSampler?
    private var textField: NSTextField?
    private let toolbar = NSView()
    private let toolbarStack = NSStackView()
    private var toolButtons: [ToolbarButton] = []
    private let stylePopover = NSPopover()
    // 面板只构建一次：反复替换 contentViewController 会让 NSPopover 重新定位，
    // 表现就是「点一下颜色，面板跳到屏幕顶上」。选样式只更新控件状态，不动视图树。
    private let paletteContainer = NSView()
    private let paletteDotGroup = NSStackView()
    private var paletteColorButtons: [NSButton] = []
    private var paletteDotButtons: [NSButton] = []
    private var paletteFontPopup: NSPopUpButton?
    private var paletteBuilt = false
    private var paletteVC: NSViewController?
    // 参考图色板顺序：红、橙、绿、蓝、黑、灰、白。
    private let presetColors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .black, .systemGray, .white]
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
    private var notice: String?

    init(snapshot: CaptureSnapshot, presetSelection: NSRect?, pinController: PinController?, centeredImage: Bool = false) {
        self.pinController = pinController
        baseCGImage = snapshot.image
        // 用 pointSize（pixelSize/scale）而不是 image.width：占位底图只有 1×1 像素，
        // 若按图片宽度反推，baseDrawRect 会缩成 1×1，选区 intersection 后直接被裁空。
        let pointSize = snapshot.pointSize

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
        buildToolbar()
        if phase == .editing {
            rebuildSampler()
            positionToolbar()
        }
        toolbar.isHidden = phase == .selecting
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
        toolbar.layer?.contentsScale = scale
        toolButtons.forEach { $0.layer?.contentsScale = scale }
        paletteColorButtons.forEach { $0.layer?.contentsScale = scale }
        paletteDotButtons.forEach { $0.layer?.contentsScale = scale }
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

    private func buildToolbar() {
        // 参考图：白色胶囊、细阴影、无粗边框。
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        // 圆角锯齿的元凶：CALayer 默认 contentsScale = 1，Retina 上按 1x 栅格化。
        toolbar.layer?.contentsScale = window?.backingScaleFactor ?? 2
        toolbar.layer?.cornerRadius = 11
        toolbar.layer?.borderWidth = 0.5
        toolbar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        toolbar.layer?.shadowColor = NSColor.black.withAlphaComponent(0.13).cgColor
        toolbar.layer?.shadowOpacity = 1
        toolbar.layer?.shadowRadius = 10
        toolbar.layer?.shadowOffset = NSSize(width: 0, height: -2)
        addSubview(toolbar)

        let stack = toolbarStack
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -5)
        ])

        // 最左侧拖拽把手（视觉元素；工具栏本身跟随选区定位）。
        let grip = ToolbarGrip()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.widthAnchor.constraint(equalToConstant: 18).isActive = true
        grip.heightAnchor.constraint(equalToConstant: 30).isActive = true
        stack.addArrangedSubview(grip)

        for item in AnnotationTool.allCases {
            let button = toolbarButton(item.symbol,
                                       tooltip: "\(item.title) · 点按可设置颜色与\(item == .text ? "字号" : "粗细")",
                                       action: #selector(selectTool(_:)),
                                       role: .tool)
            button.tag = item.rawValue
            toolButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(separator())

        let undoButton = toolbarButton("arrow.uturn.backward", tooltip: "撤销（⌘Z）", action: #selector(undo(_:)), role: .action)
        let redoButton = toolbarButton("arrow.uturn.forward", tooltip: "重做（⇧⌘Z）", action: #selector(redo(_:)), role: .action)
        undoButton.identifier = NSUserInterfaceItemIdentifier("undo")
        redoButton.identifier = NSUserInterfaceItemIdentifier("redo")
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)

        stack.addArrangedSubview(separator())

        // 参考图里的下载图标 = 保存 PNG；Pin 与复制放在溢出位置，避免主栏拥挤。
        stack.addArrangedSubview(toolbarButton("square.and.arrow.down", tooltip: "保存为 PNG（⌘S）", action: #selector(saveImage(_:)), role: .action))
        stack.addArrangedSubview(toolbarButton("pin", tooltip: "钉住到桌面", action: #selector(pinImage(_:)), role: .action))

        stack.addArrangedSubview(separator())

        stack.addArrangedSubview(toolbarButton("xmark", tooltip: "取消（Esc）", action: #selector(cancel(_:)), role: .destructive))
        stack.addArrangedSubview(toolbarButton("checkmark", tooltip: "复制并退出（Return）", action: #selector(copyImage(_:)), role: .confirm))

        refreshToolbarState()
    }

    private func toolbarButton(_ symbol: String, tooltip: String, action: Selector, role: ToolbarButton.Role) -> ToolbarButton {
        let button = ToolbarButton()
        // 参考图是细线图标（约 16-17pt、regular 字重），不是加粗实心。
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(configuration)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.role = role
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.layer?.contentsScale = window?.backingScaleFactor ?? 2
        button.refreshAppearance()
        return button
    }

    private func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }

    private func refreshToolbarState() {
        for button in toolButtons {
            button.isActiveTool = button.tag == tool.rawValue
            button.refreshAppearance()
        }
        if let undoButton = toolbarStack.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: { $0.identifier?.rawValue == "undo" }) {
            undoButton.isEnabled = !annotations.isEmpty
        }
        if let redoButton = toolbarStack.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: { $0.identifier?.rawValue == "redo" }) {
            redoButton.isEnabled = !redoStack.isEmpty
        }
    }

    /// 点工具按钮：切换工具，并在按钮正下方弹出参考图那种样式面板。
    private func presentStylePopover(for toolButton: NSButton) {
        ensurePalette()
        syncPaletteState()
        // 先落定工具栏尺寸，避免面板锚点算在旧 frame 上。
        toolbar.layoutSubtreeIfNeeded()
        if stylePopover.isShown {
            // 已显示时换锚点必须重开，否则面板停在旧按钮下面。
            stylePopover.performClose(nil)
            DispatchQueue.main.async { [weak self, weak toolButton] in
                guard let self, let toolButton else { return }
                self.stylePopover.show(relativeTo: toolButton.bounds, of: toolButton, preferredEdge: .minY)
            }
        } else {
            stylePopover.show(relativeTo: toolButton.bounds, of: toolButton, preferredEdge: .minY)
        }
    }

    /// 构建一次面板。故意不给容器画背景和圆角——交给系统 NSPopover 渲染，
    /// 圆角和箭头都是原生抗锯齿，比手写 CALayer 圆角平滑得多。
    private func ensurePalette() {
        guard !paletteBuilt else { return }
        paletteBuilt = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        paletteContainer.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: paletteContainer.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: paletteContainer.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: paletteContainer.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: paletteContainer.bottomAnchor, constant: -9)
        ])

        // 粗细圆点组（形状类工具用）
        paletteDotGroup.orientation = .horizontal
        paletteDotGroup.alignment = .centerY
        paletteDotGroup.spacing = 3
        for (index, width) in presetLineWidths.enumerated() {
            let dot = NSButton(title: "", target: self, action: #selector(selectLineWidth(_:)))
            dot.tag = index
            dot.isBordered = false
            dot.bezelStyle = .regularSquare
            dot.wantsLayer = true
            dot.layer?.contentsScale = window?.backingScaleFactor ?? 2
            dot.layer?.cornerRadius = 8
            let diameter: CGFloat = [5, 8, 11][index]
            let dotImage = NSImage(systemSymbolName: "circle.fill",
                                   accessibilityDescription: "\(Int(width))px")
            dot.image = dotImage?.withSymbolConfiguration(.init(pointSize: diameter, weight: .semibold))
            dot.toolTip = "\(Int(width)) px"
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 26).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 28).isActive = true
            paletteDotButtons.append(dot)
            paletteDotGroup.addArrangedSubview(dot)
        }
        row.addArrangedSubview(paletteDotGroup)

        // 字号下拉（文字工具用），与圆点组互斥显示；宽度对齐圆点组，保证两种模式同宽。
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 84, height: 24), pullsDown: false)
        for size in presetTextSizes { popup.addItem(withTitle: "\(Int(size))pt") }
        popup.target = self
        popup.action = #selector(selectFontSize(_:))
        popup.font = .systemFont(ofSize: 12, weight: .medium)
        popup.controlSize = .small
        popup.toolTip = "文字字号"
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 84).isActive = true
        paletteFontPopup = popup
        row.addArrangedSubview(popup)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(divider)

        for (index, color) in presetColors.enumerated() {
            let button = makeColorSwatch(color, tag: index)
            paletteColorButtons.append(button)
            row.addArrangedSubview(button)
        }

        let vc = NSViewController()
        vc.view = paletteContainer
        // 先按当前工具定好圆点组/下拉的显隐，再算尺寸；
        // 否则会把隐藏控件也计入宽度，面板中间多出一段空白。
        syncPaletteState()
        let fit = paletteFittingSize()
        vc.preferredContentSize = NSSize(width: ceil(fit.width), height: ceil(fit.height))
        paletteVC = vc
        stylePopover.contentViewController = vc
        stylePopover.behavior = .transient
        stylePopover.animates = false
    }

    /// 让面板容器在临时 frame 下求解一次约束，得到内容的真实尺寸。
    private func paletteFittingSize() -> NSSize {
        paletteContainer.frame = NSRect(x: 0, y: 0, width: 320, height: 46)
        paletteContainer.layoutSubtreeIfNeeded()
        return paletteContainer.fittingSize
    }

    /// 原地同步面板状态：选颜色/粗细/字号后调用，绝不重建视图，面板位置因此纹丝不动。
    private func syncPaletteState() {
        let usesTextSize = tool == .text
        paletteDotGroup.isHidden = usesTextSize
        paletteFontPopup?.isHidden = !usesTextSize

        for (index, button) in paletteColorButtons.enumerated() {
            guard presetColors.indices.contains(index) else { continue }
            let color = presetColors[index]
            let selected = color.isEqual(annotationColor)
            button.layer?.borderWidth = selected ? 2 : 0.5
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            button.image = selected
                ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已选中")?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
                : nil
            let resolved = color.usingColorSpace(.deviceRGB)
            button.contentTintColor = (resolved?.brightnessComponent ?? 0.5) < 0.55 ? .white : .black
        }

        for (index, dot) in paletteDotButtons.enumerated() {
            guard presetLineWidths.indices.contains(index) else { continue }
            let selected = presetLineWidths[index] == annotationLineWidth
            dot.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
                : NSColor.clear.cgColor
            dot.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        }

        paletteFontPopup?.selectItem(at: presetTextSizes.firstIndex(of: annotationTextFontSize) ?? 1)
        paletteContainer.layoutSubtreeIfNeeded()
    }

    private func colorName(_ color: NSColor) -> String {
        let names = ["红", "橙", "绿", "蓝", "黑", "灰", "白"]
        return presetColors.enumerated().first(where: { $0.element.isEqual(color) }).map { names[$0.offset] } ?? "自定"
    }

    private func makeColorSwatch(_ color: NSColor, tag: Int) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectColor(_:)))
        button.tag = tag
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 5
        button.layer?.contentsScale = window?.backingScaleFactor ?? 2
        button.toolTip = "\(colorName(color))色"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 21).isActive = true
        button.heightAnchor.constraint(equalToConstant: 21).isActive = true
        return button
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard presetColors.indices.contains(sender.tag) else { return }
        annotationColor = presetColors[sender.tag]
        syncPaletteState()
        needsDisplay = true
    }

    @objc private func selectLineWidth(_ sender: NSButton) {
        guard presetLineWidths.indices.contains(sender.tag) else { return }
        annotationLineWidth = presetLineWidths[sender.tag]
        syncPaletteState()
        needsDisplay = true
    }

    @objc private func selectFontSize(_ sender: NSPopUpButton) {
        guard presetTextSizes.indices.contains(sender.indexOfSelectedItem) else { return }
        annotationTextFontSize = presetTextSizes[sender.indexOfSelectedItem]
        syncPaletteState()
        needsDisplay = true
    }

    private func positionToolbar() {
        guard phase == .editing, !selection.isEmpty, !toolbar.isHidden else { return }
        toolbar.layoutSubtreeIfNeeded()
        // 宽度跟着内容走。之前硬编码下限 500，内容只有 ~410，右侧就多出一大截空白。
        let width = ceil(toolbarStack.fittingSize.width) + 14
        let height = ceil(toolbarStack.fittingSize.height) + 10
        var y = selection.maxY + 8
        if y + height > bounds.height { y = selection.minY - height - 8 }
        if y < 0 { y = max(bounds.height - height - 8, 0) }
        let x = min(max(selection.midX - width / 2, 8), max(bounds.width - width - 8, 8))
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if toolbar.frame != frame { toolbar.frame = frame }
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

        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        bounds.fill()
        // 底图按原始像素落位：与窗口缩放一致时禁用插值，保证预览和导出一样锐利。
        let drawScale = CGFloat(baseCGImage.width) / max(baseDrawRect.width, 1)
        let viewScale = window?.backingScaleFactor ?? 1
        let baseQuality: CGInterpolationQuality = abs(drawScale - viewScale) < 0.01 ? .none : .high
        context.drawUprightCGImage(baseCGImage, in: baseDrawRect, quality: baseQuality)

        if phase == .selecting {
            let dim = NSBezierPath(rect: bounds)
            if !selection.isEmpty { dim.append(NSBezierPath(rect: selection)) }
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.35).setFill()
            dim.fill()
            drawSelectionChrome()
            return
        }

        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: selection))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        context.saveGState()
        let clip = selection.intersection(bounds)
        context.clip(to: clip)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, offset: .zero, sampler: sampler,
                                    samplerOrigin: selection.origin, scale: scale)
        }
        if let draftRect {
            let path = NSBezierPath(rect: draftRect)
            path.lineWidth = annotationLineWidth
            annotationColor.setStroke()
            path.stroke()
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
        // 样式面板是 transient：点画布时关掉，避免挡住正在标注的位置。
        if stylePopover.isShown { stylePopover.performClose(nil) }
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
        toolbar.isHidden = false
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

    @objc private func selectTool(_ sender: NSButton) {
        guard let selected = AnnotationTool(rawValue: sender.tag) else { return }
        let sameTool = tool == selected
        tool = selected
        refreshToolbarState()
        if sameTool && stylePopover.isShown {
            stylePopover.performClose(sender)
        } else {
            presentStylePopover(for: sender)
        }
    }

    @objc private func undo(_ sender: Any?) {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        if case .number = last.kind { nextNumber = max(1, nextNumber - 1) }
        refreshToolbarState()
        needsDisplay = true
    }

    @objc private func redo(_ sender: Any?) {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
        refreshToolbarState()
        needsDisplay = true
    }

    @objc private func cancel(_ sender: Any?) { finish() }

    @objc private func copyImage(_ sender: Any?) {
        guard let image = renderSelection() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showNotice("已复制到剪贴板")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.finish() }
    }

    @objc private func saveImage(_ sender: Any?) {
        guard let cgImage = renderSelectionCGImage(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PinSnap-\(Int(Date().timeIntervalSince1970)).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.showNotice("已保存")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self?.finish() }
            } catch {
                NSSound.beep()
            }
        }
    }

    @objc private func pinImage(_ sender: Any?) {
        guard let image = renderSelection() else { return }
        // 固定到截图所在的那块屏幕，而不是「当前主屏」。
        pinController?.pin(image, on: window?.screen)
        finish()
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

    /// 自测：弹出面板 → 换色 → 面板位置必须不变（防回归：替换 contentViewController 导致的跳位）。
    func autotestPaletteStability() -> String {
        guard phase == .editing, let firstTool = toolButtons.first else { return "no-editor" }
        tool = .rectangle
        refreshToolbarState()
        presentStylePopover(for: firstTool)
        let vcBefore = stylePopover.contentViewController
        let frameBefore = paletteContainer.frame
        let before = stylePopover.positioningRect
        if paletteColorButtons.indices.contains(2) {
            selectColor(paletteColorButtons[2])
        }
        let vcAfter = stylePopover.contentViewController
        let frameAfter = paletteContainer.frame
        let after = stylePopover.positioningRect
        // 根因断言：换色后 VC 与容器尺寸必须原样不动，位置才不会被重算。
        let sameVC = vcBefore === vcAfter
        let sameFrame = frameBefore == frameAfter
        let dx = abs(before.minX - after.minX)
        let dy = abs(before.minY - after.minY)
        return "shown=\(stylePopover.isShown) sameVC=\(sameVC) sameFrame=\(sameFrame) "
            + "posDelta=(\(Int(dx)),\(Int(dy))) stable=\(sameVC && sameFrame && dx < 0.5 && dy < 0.5)"
    }

    /// 自测：把工具栏视图离屏渲染成 PNG，用于无截屏环境下的视觉回归。
    func autotestDumpToolbar(to path: String) -> String {
        guard phase == .editing else { return "no-editor" }
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.bounds.size
        guard size.width > 1, size.height > 1 else { return "empty-toolbar" }
        let rect = NSRect(origin: .zero, size: size)
        guard let rep = toolbar.bitmapImageRepForCachingDisplay(in: rect) else { return "no-rep" }
        toolbar.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "toolbar=\(Int(size.width))x\(Int(size.height))"
    }

    /// 自测：渲染样式面板（shape=圆点粗细 + 色板，text=字号下拉 + 色板）。
    func autotestDumpPalette(text: Bool, to path: String) -> String {
        guard phase == .editing else { return "no-editor" }
        let previousTool = tool
        tool = text ? .text : .rectangle
        refreshToolbarState()
        defer {
            tool = previousTool
            refreshToolbarState()
        }
        ensurePalette()
        syncPaletteState()
        let fit = paletteFittingSize()
        paletteContainer.frame = NSRect(origin: .zero, size: fit)
        paletteContainer.layoutSubtreeIfNeeded()
        let size = fit
        guard size.width > 1, size.height > 1 else { return "empty-palette" }
        let rect = NSRect(origin: .zero, size: size)
        guard let rep = paletteContainer.bitmapImageRepForCachingDisplay(in: rect) else { return "no-rep" }
        paletteContainer.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "palette=\(Int(size.width))x\(Int(size.height))"
    }

    /// 自测：渲染「选区 + 标注 + 工具栏」整体区域，验证所见即所得。
    func autotestDumpEditorRegion(to path: String) -> String {
        guard phase == .editing, !selection.isEmpty else { return "no-editor" }
        toolbar.layoutSubtreeIfNeeded()
        var region = selection.insetBy(dx: -50, dy: -50)
        region.size.height += 130 + toolbar.bounds.height
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
        rebuildSampler()
        needsDisplay = true
    }

    func dumpBaseImage(to path: String) -> String {
        let rep = NSBitmapImageRep(cgImage: baseCGImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no-png" }
        try? data.write(to: URL(fileURLWithPath: path))
        return "base=\(baseCGImage.width)x\(baseCGImage.height) selection=\(selection)"
    }

    /// 只转储“用户实际看到的选区画面”（不含工具栏、遮罩、边框），
    /// 用于和导出图做像素级比对，验证「所见」与「所得」是否一致。
    func dumpSelectionView(to path: String) -> String {
        guard !selection.isEmpty else { return "no-selection" }
        let wasHidden = toolbar.isHidden
        toolbar.isHidden = true
        suppressChrome = true
        defer {
            toolbar.isHidden = wasHidden
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
