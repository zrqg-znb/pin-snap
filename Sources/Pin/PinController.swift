import Cocoa
import UniformTypeIdentifiers

final class PinController {
    /// 防止多张高分辨率整屏截图常驻导致内存持续上涨。
    /// 预算以原始位图的 BGRA 估算，给常见双 4K 工作流留出空间，同时保证可预期地淘汰最早 Pin。
    private static let maximumPinnedWindows = 8
    private static let maximumPinnedBytes = 256 * 1024 * 1024

    private var windows: [PinnedWindow] = []
    private var estimatedPinnedBytes = 0

    var pinnedCount: Int { windows.count }
    var estimatedMemoryBytes: Int { estimatedPinnedBytes }

    @discardableResult
    func pin(_ image: NSImage, on screen: NSScreen? = nil) -> Int {
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? CGImageMini.placeholder
        let bytes = Self.estimatedBytes(for: cgImage)
        var evicted = 0
        while let oldest = windows.first,
              windows.count >= Self.maximumPinnedWindows || estimatedPinnedBytes + bytes > Self.maximumPinnedBytes {
            evicted += 1
            oldest.close()
        }

        let window = PinnedWindow(image: image, imageBytes: bytes, screen: screen) { [weak self] closed in
            self?.remove(closed)
        }
        windows.append(window)
        estimatedPinnedBytes += bytes
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return evicted
    }

    @discardableResult
    func closeAll() -> Int {
        let closing = windows
        closing.forEach { $0.close() }
        return closing.count
    }

    private func remove(_ window: PinnedWindow) {
        guard let index = windows.firstIndex(where: { $0 === window }) else { return }
        estimatedPinnedBytes = max(0, estimatedPinnedBytes - windows[index].estimatedImageBytes)
        windows.remove(at: index)
    }

    private static func estimatedBytes(for image: CGImage) -> Int {
        let raw = image.bytesPerRow * image.height
        // 从异常或不完整图像得到 0 时按 BGRA 位图下限估算，避免绕开预算。
        return max(raw, image.width * image.height * 4)
    }

    /// 自测用：最近一个 Pin 窗口的 frame，供测试挑选窗口内的锚点。
    var autotestLastFrame: NSRect? { windows.last?.frame }

    /// 自测用：对最近一个 Pin 窗口执行缩放，返回缩放前后的锚点相对位置。
    func autotestZoomLast(factor: CGFloat, at anchor: NSPoint) -> String {
        guard let window = windows.last else { return "no-window" }
        return window.autotestZoom(factor: factor, anchor: anchor)
    }

    func autotestCloseAll() -> String {
        let closed = closeAll()
        return "closed=\(closed) remaining=\(pinnedCount) bytes=\(estimatedMemoryBytes)"
    }
}

final class PinnedWindow: NSPanel {
    fileprivate let estimatedImageBytes: Int
    private let closed: (PinnedWindow) -> Void
    private var didReportClose = false

    init(image: NSImage,
         imageBytes: Int,
         screen targetScreen: NSScreen?,
         closed: @escaping (PinnedWindow) -> Void) {
        self.estimatedImageBytes = imageBytes
        self.closed = closed
        let pointSize = image.size.width > 1 ? image.size : NSSize(width: 320, height: 240)
        let screen = (targetScreen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = (targetScreen ?? NSScreen.main)?.backingScaleFactor ?? 2
        func aligned(_ value: CGFloat) -> CGFloat { (value * screenScale).rounded() / screenScale }

        // 以屏幕全尺寸（不是 visibleFrame）作为上限：整屏截图固定后仍是 1:1，文字不会被压缩。
        let fit = min(1, min(screen.width / max(pointSize.width, 1),
                             screen.height / max(pointSize.height, 1)))
        let size = NSSize(width: max(160, aligned(pointSize.width * fit)),
                          height: max(110, aligned(pointSize.height * fit)))
        let origin = NSPoint(x: aligned(screen.midX - size.width / 2),
                             y: aligned(screen.midY - size.height / 2))
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? CGImageMini.placeholder

        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        // 由 PinController 强持有，禁止 AppKit 在 close() 时再 release 一次。
        isReleasedWhenClosed = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true
        minSize = NSSize(width: 120, height: 80)
        contentView = PinnedContentView(image: image,
                                        cgImage: cgImage,
                                        pointSize: pointSize,
                                        onClose: { [weak self] in self?.close() })
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func autotestZoom(factor: CGFloat, anchor: NSPoint) -> String {
        guard let view = contentView as? PinnedContentView else { return "no-view" }
        let before = frame
        let rx = (anchor.x - before.minX) / max(before.width, 1)
        let ry = (anchor.y - before.minY) / max(before.height, 1)
        view.autotestZoom(factor: factor, anchor: anchor)
        let after = frame
        let rx2 = (anchor.x - after.minX) / max(after.width, 1)
        let ry2 = (anchor.y - after.minY) / max(after.height, 1)
        return String(format: "before=%.0fx%.0f after=%.0fx%.0f anchorX %.4f->%.4f anchorY %.4f->%.4f",
                      before.width, before.height, after.width, after.height, rx, rx2, ry, ry2)
    }

    override func close() {
        super.close()
        guard !didReportClose else { return }
        didReportClose = true
        closed(self)
    }
}

private final class PinnedContentView: NSView {
    private enum Zone {
        case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    }

    private let image: NSImage
    private let cgImage: CGImage
    private let imagePointSize: NSSize
    private let onClose: () -> Void
    private let closeButton = NSButton()
    private var closeTarget: BlockTarget?
    private var closeTopConstraint: NSLayoutConstraint?
    private var closeTrailingConstraint: NSLayoutConstraint?
    private var hover = false {
        didSet { closeButton.animator().alphaValue = hover ? 1 : 0.5 }
    }

    private var activeZone: Zone = .move
    private var dragging = false
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero
    private var startAspect: CGFloat = 1
    private var tracking: NSTrackingArea?

    private var zoom: CGFloat = 1
    private var zoomBadge: String?
    private var badgeToken = 0

    private let edge: CGFloat = 9
    private let minSide: CGFloat = 120

    init(image: NSImage, cgImage: CGImage, pointSize: NSSize, onClose: @escaping () -> Void) {
        self.image = image
        self.cgImage = cgImage
        self.imagePointSize = pointSize
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor

        let target = BlockTarget { onClose() }
        closeTarget = target
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.alphaValue = 0.5
        closeButton.target = target
        closeButton.action = #selector(BlockTarget.invoke)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        let topConstraint = closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        let trailingConstraint = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        closeTopConstraint = topConstraint
        closeTrailingConstraint = trailingConstraint
        NSLayoutConstraint.activate([
            topConstraint,
            trailingConstraint,
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncLayerScale()
        syncZoom()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        updateSafeInsets()
    }

    /// 全屏 Pin 会伸到菜单栏 / Dock 底下，按钮和抓手要跟着让开，否则点不到。
    private var safeTopInset: CGFloat {
        guard let window, let screen = window.screen ?? NSScreen.main else { return 0 }
        let overlap = screen.visibleFrame.maxY - window.frame.maxY
        return min(max(overlap, 0), max(window.frame.height / 3, 0))
    }

    private var safeBottomInset: CGFloat {
        guard let window, let screen = window.screen ?? NSScreen.main else { return 0 }
        let overlap = screen.visibleFrame.minY - window.frame.minY
        return min(max(overlap, 0), max(window.frame.height / 3, 0))
    }

    private var safeRightInset: CGFloat {
        guard let window, let screen = window.screen ?? NSScreen.main else { return 0 }
        let overlap = window.frame.maxX - screen.visibleFrame.maxX
        return min(max(overlap, 0), max(window.frame.width / 3, 0))
    }

    private func updateSafeInsets() {
        let top = 6 + safeTopInset
        let trailing = -(6 + safeRightInset)
        var changed = false
        if let closeTopConstraint, abs(closeTopConstraint.constant - top) > 0.5 {
            closeTopConstraint.constant = top
            changed = true
        }
        if let closeTrailingConstraint, abs(closeTrailingConstraint.constant - trailing) > 0.5 {
            closeTrailingConstraint.constant = trailing
            changed = true
        }
        if changed { needsDisplay = true }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerScale()
        needsDisplay = true
    }

    private func syncLayerScale() {
        guard let scale = window?.backingScaleFactor else { return }
        layer?.contentsScale = scale
    }

    private func aligned(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    private func syncZoom() {
        guard let window, imagePointSize.width > 1 else { return }
        zoom = window.frame.width / imagePointSize.width
    }

    /// 1:1 与整数倍放大用最近邻，避免任何重采样发虚；其余比例用高质量插值。
    private var interpolationQuality: CGInterpolationQuality {
        if abs(zoom - 1) < 0.005 { return .none }
        if zoom > 1, abs(zoom - zoom.rounded()) < 0.005 { return .none }
        return .high
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // 铺满整块内容区：不做 1pt 内缩，否则整张图会被压扁 0.2% 而整体发糊。
        context.drawUprightCGImage(cgImage, in: bounds, quality: interpolationQuality)
        drawGrip()
        drawZoomBadge()
    }

    private func drawGrip() {
        let gripSide: CGFloat = 14
        let grip = NSRect(x: bounds.maxX - gripSide - safeRightInset,
                          y: bounds.maxY - gripSide - safeBottomInset,
                          width: gripSide, height: gripSide)
        NSColor.white.withAlphaComponent(0.32).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: grip.minX + 4, y: grip.maxY - 3))
        path.line(to: NSPoint(x: grip.maxX - 3, y: grip.minY + 4))
        path.move(to: NSPoint(x: grip.minX + 9, y: grip.maxY - 3))
        path.line(to: NSPoint(x: grip.maxX - 3, y: grip.minY + 9))
        path.stroke()
    }

    private func drawZoomBadge() {
        guard let zoomBadge else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = zoomBadge.size(withAttributes: attributes)
        let box = NSRect(x: bounds.midX - size.width / 2 - 8, y: 10 + safeBottomInset,
                         width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        zoomBadge.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
    }

    private func flashZoomBadge() {
        badgeToken += 1
        let token = badgeToken
        zoomBadge = "\(Int((zoom * 100).rounded()))%"
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.badgeToken == token else { return }
            self.zoomBadge = nil
            self.needsDisplay = true
        }
    }

    // MARK: - 滚轮 / 触控板缩放（以光标为中心）

    override func scrollWheel(with event: NSEvent) {
        // 惯性滚动继续缩放会失控，直接忽略。
        guard event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.0001 else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.010 : 0.08
        applyZoom(factor: exp(delta * sensitivity), anchor: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        guard factor > 0 else { return }
        applyZoom(factor: factor, anchor: NSEvent.mouseLocation)
    }

    override func smartMagnify(with event: NSEvent) {
        resizeToActualSize()
    }

    private func applyZoom(factor: CGFloat, anchor: NSPoint) {
        guard let window, factor.isFinite, factor > 0,
              let target = zoomedFrame(factor: factor, anchor: anchor) else { return }
        window.setFrame(target, display: true)
        syncZoom()
        updateSafeInsets()
        needsDisplay = true
        window.invalidateCursorRects(for: self)
        flashZoomBadge()
    }

    func autotestZoom(factor: CGFloat, anchor: NSPoint) {
        applyZoom(factor: factor, anchor: anchor)
    }

    /// 按倍数计算新窗口矩形，并保证光标下的那个图像点位置不动。
    private func zoomedFrame(factor: CGFloat, anchor: NSPoint) -> NSRect? {
        guard let window, imagePointSize.width > 1 else { return nil }
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return nil }

        let aspect = imagePointSize.width / max(imagePointSize.height, 1)
        let screen = window.screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let minWidth = max(120, imagePointSize.width * 0.04)
        let maxWidth = min(imagePointSize.width * 6, max(screen.width * 3, 640))
        let width = min(max(frame.width * factor, minWidth), maxWidth)
        guard abs(width - frame.width) > 0.01 else { return nil }
        let height = width / max(aspect, 0.05)

        // 光标在窗口内的相对位置保持不变，缩放后该位置的图像内容仍停在光标下。
        let ratioX = (anchor.x - frame.minX) / frame.width
        let ratioY = (anchor.y - frame.minY) / frame.height
        let x = anchor.x - ratioX * width
        let y = anchor.y - ratioY * height
        return NSRect(x: aligned(x), y: aligned(y),
                      width: aligned(width), height: aligned(height))
    }

    // MARK: - 拖拽 / 缩放

    private func zone(at point: NSPoint) -> Zone {
        let inLeft = point.x <= edge
        let inRight = point.x >= bounds.width - edge
        let inTop = point.y <= edge
        let inBottom = point.y >= bounds.height - edge
        switch (inLeft, inRight, inTop, inBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return .move
        }
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - edge, width: bounds.width, height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - edge, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: edge, height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: bounds.width - edge, y: 0, width: edge, height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - edge, width: edge, height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: bounds.width - edge, y: bounds.height - edge, width: edge, height: edge), cursor: .resizeUpDown)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncZoom()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            resizeToActualSize()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        activeZone = zone(at: point)
        dragging = true
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
        startAspect = max(window.frame.width / max(window.frame.height, 1), 0.05)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, dragging else { return }
        let now = NSEvent.mouseLocation
        let deltaX = now.x - startMouse.x
        let deltaY = now.y - startMouse.y

        if activeZone == .move {
            var origin = NSPoint(x: startFrame.origin.x + deltaX, y: startFrame.origin.y + deltaY)
            if let visible = window.screen?.visibleFrame {
                let minVisible: CGFloat = 60
                origin.x = min(max(origin.x, visible.minX - startFrame.width + minVisible), visible.maxX - minVisible)
                origin.y = min(max(origin.y, visible.minY - startFrame.height + minVisible), visible.maxY - minVisible)
            }
            window.setFrameOrigin(NSPoint(x: aligned(origin.x), y: aligned(origin.y)))
            return
        }

        // 默认锁定宽高比，按住 Shift 自由拉伸。
        let lockAspect = !event.modifierFlags.contains(.shift)
        var frame = startFrame
        let growsRight = (activeZone == .right || activeZone == .topRight || activeZone == .bottomRight)
        let growsLeft = (activeZone == .left || activeZone == .topLeft || activeZone == .bottomLeft)
        let growsUp = (activeZone == .top || activeZone == .topLeft || activeZone == .topRight)
        let growsDown = (activeZone == .bottom || activeZone == .bottomLeft || activeZone == .bottomRight)

        if growsRight { frame.size.width = max(minSide, startFrame.width + deltaX) }
        if growsLeft {
            let width = max(minSide, startFrame.width - deltaX)
            frame.origin.x = startFrame.maxX - width
            frame.size.width = width
        }
        if growsUp {
            let height = max(minSide, startFrame.height + deltaY)
            frame.origin.y = startFrame.maxY - height
            frame.size.height = height
        }
        if growsDown { frame.size.height = max(minSide, startFrame.height - deltaY) }

        if lockAspect {
            switch activeZone {
            case .left, .right:
                frame.size.height = max(minSide, frame.width / startAspect)
                frame.origin.y = startFrame.midY - frame.height / 2
            case .top, .bottom:
                frame.size.width = max(minSide, frame.height * startAspect)
                frame.origin.x = startFrame.midX - frame.width / 2
            case .topLeft:
                frame.size.height = max(minSide, frame.width / startAspect)
                frame.origin.y = startFrame.maxY - frame.height
            case .topRight, .bottomRight, .bottomLeft:
                frame.size.height = max(minSide, frame.width / startAspect)
            default:
                break
            }
        }
        let alignedFrame = NSRect(x: aligned(frame.origin.x), y: aligned(frame.origin.y),
                                  width: aligned(frame.width), height: aligned(frame.height))
        window.setFrame(alignedFrame, display: true)
        syncZoom()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        syncZoom()
        updateSafeInsets()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "复制图片", action: #selector(copyImage), keyEquivalent: "c")
        copy.target = self
        let save = menu.addItem(withTitle: "保存 PNG…", action: #selector(saveImage), keyEquivalent: "s")
        save.target = self
        menu.addItem(.separator())
        let fit = menu.addItem(withTitle: "实际大小（100%）", action: #selector(resizeToActualSize), keyEquivalent: "")
        fit.target = self
        let close = menu.addItem(withTitle: "关闭", action: #selector(closeSelf), keyEquivalent: "")
        close.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose() } else { super.keyDown(with: event) }
    }

    @objc private func resizeToActualSize() {
        guard let window else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let size = imagePointSize
        let frame = NSRect(x: aligned(center.x - size.width / 2),
                           y: aligned(center.y - size.height / 2),
                           width: aligned(size.width),
                           height: aligned(size.height))
        window.setFrame(frame, display: true)
        syncZoom()
        needsDisplay = true
        flashZoomBadge()
    }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func saveImage() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PinSnap-\(Int(Date().timeIntervalSince1970)).png"
        panel.beginSheetModal(for: window) { [image] response in
            guard response == .OK, let url = panel.url,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    @objc private func closeSelf() { onClose() }
}

private final class BlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}
