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

    func exportedImage() -> NSImage? { editor.renderSelection() }

    func exportedCGImage() -> CGImage? { editor.renderSelectionCGImage() }

    func dumpBaseImage(to path: String) -> String { editor.dumpBaseImage(to: path) }

    func seedTestAnnotations() { editor.seedTestAnnotations() }

    func autotestVerifyGeometry() -> String { editor.autotestVerifyGeometry() }

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

final class CaptureEditView: NSView, NSTextFieldDelegate {
    var onFinish: (() -> Void)?

    private enum Phase { case selecting, editing }

    private let baseCGImage: CGImage
    private let baseDrawRect: NSRect
    private let scale: CGFloat
    private let pinController: PinController?
    private var phase: Phase
    private var selection: NSRect
    private var startPoint: NSPoint?
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
    private var toolButtons: [NSButton] = []
    private var notice: String?

    init(snapshot: CaptureSnapshot, presetSelection: NSRect?, pinController: PinController?, centeredImage: Bool = false) {
        self.pinController = pinController
        baseCGImage = snapshot.image
        let captureScale = max(snapshot.scale, 0.5)
        let pointSize = NSSize(width: CGFloat(snapshot.image.width) / captureScale,
                               height: CGFloat(snapshot.image.height) / captureScale)

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
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: phase == .selecting ? .crosshair : .arrow)
    }

    private func buildToolbar() {
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor
        toolbar.layer?.cornerRadius = 8
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        addSubview(toolbar)

        let stack = toolbarStack
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -4)
        ])

        for item in AnnotationTool.allCases {
            let button = iconButton(item.symbol, tooltip: item.title, action: #selector(selectTool(_:)))
            button.tag = item.rawValue
            toolButtons.append(button)
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(iconButton("arrow.uturn.backward", tooltip: "撤销 (⌘Z)", action: #selector(undo(_:))))
        stack.addArrangedSubview(iconButton("arrow.uturn.forward", tooltip: "重做 (⇧⌘Z)", action: #selector(redo(_:))))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(iconButton("xmark", tooltip: "取消 (Esc)", action: #selector(cancel(_:))))
        stack.addArrangedSubview(iconButton("doc.on.doc", tooltip: "复制 (Return)", action: #selector(copyImage(_:))))
        stack.addArrangedSubview(iconButton("square.and.arrow.down", tooltip: "保存 PNG (⌘S)", action: #selector(saveImage(_:))))
        stack.addArrangedSubview(iconButton("pin.fill", tooltip: "Pin 到桌面", action: #selector(pinImage(_:))))

        highlightTool()
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.2).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }

    private func highlightTool() {
        for button in toolButtons {
            button.contentTintColor = button.tag == tool.rawValue ? .systemBlue : .white
        }
    }

    private func positionToolbar() {
        guard phase == .editing, !selection.isEmpty, !toolbar.isHidden else { return }
        let fitted = toolbarStack.fittingSize.width
        let width = max(fitted + 12, 400)
        var y = selection.maxY + 8
        if y + 36 > bounds.height { y = selection.minY - 44 }
        if y < 0 { y = max(bounds.height - 44, 0) }
        let x = min(max(selection.midX - width / 2, 8), max(bounds.width - width - 8, 8))
        let frame = NSRect(x: x, y: y, width: width, height: 36)
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
            path.lineWidth = AnnotationRenderer.lineWidth
            NSColor.systemRed.setStroke()
            path.stroke()
        }
        if let draftArrow {
            AnnotationRenderer.drawArrow(from: draftArrow.start, to: draftArrow.end,
                                         color: .systemRed,
                                         lineWidth: AnnotationRenderer.lineWidth)
        }
        if activePoints.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = AnnotationRenderer.penWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: activePoints[0])
            for point in activePoints.dropFirst() { path.line(to: point) }
            NSColor.systemRed.setStroke()
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
        guard selection.contains(point) else { return }
        if let textField {
            commitText(textField)
        }
        switch tool {
        case .pen:
            activePoints = [point]
        case .number:
            annotations.append(Annotation(kind: .number(nextNumber), start: point, end: point,
                                          points: [], color: .systemRed, lineWidth: 0))
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
        switch tool {
        case .pen:
            if activePoints.count > 1 {
                annotations.append(Annotation(kind: .pen, start: activePoints[0], end: point,
                                              points: activePoints, color: .systemRed,
                                              lineWidth: AnnotationRenderer.penWidth))
                redoStack.removeAll()
            }
            activePoints = []
        case .rectangle, .mosaic:
            if let rect = draftRect, rect.width > 3, rect.height > 3 {
                annotations.append(Annotation(kind: tool == .rectangle ? .rectangle : .mosaic,
                                              start: rect.origin,
                                              end: NSPoint(x: rect.maxX, y: rect.maxY),
                                              points: [], color: .systemRed,
                                              lineWidth: AnnotationRenderer.lineWidth))
                redoStack.removeAll()
            }
            draftRect = nil
            startPoint = nil
        case .arrow:
            if let arrow = draftArrow, hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y) > 6 {
                annotations.append(Annotation(kind: .arrow, start: arrow.start, end: arrow.end,
                                              points: [], color: .systemRed,
                                              lineWidth: AnnotationRenderer.lineWidth))
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

    private func presentTextField(at point: NSPoint) {
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 14, width: 220, height: 30))
        field.font = .systemFont(ofSize: 22, weight: .semibold)
        field.textColor = .systemRed
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        field.delegate = self
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) { commitText(sender) }

    private func commitText(_ field: NSTextField) {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let origin = textField?.frame.origin else { return }
        if !value.isEmpty {
            annotations.append(Annotation(kind: .text(value), start: NSPoint(x: origin.x, y: origin.y),
                                          end: NSPoint(x: origin.x, y: origin.y + 28),
                                          points: [], color: .systemRed, lineWidth: 0))
            redoStack.removeAll()
        }
        field.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textView.string = ""
            if let textField { self.textField = nil; textField.removeFromSuperview() }
            window?.makeFirstResponder(self)
            needsDisplay = true
            return true
        }
        return false
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let selected = AnnotationTool(rawValue: sender.tag) else { return }
        tool = selected
        highlightTool()
    }

    @objc private func undo(_ sender: Any?) {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        if case .number = last.kind { nextNumber = max(1, nextNumber - 1) }
        needsDisplay = true
    }

    @objc private func redo(_ sender: Any?) {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
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
        onFinish?()
    }

    func detachTextInput() {
        textField?.removeFromSuperview()
        textField = nil
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
