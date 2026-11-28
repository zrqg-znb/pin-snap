import Cocoa

/// 截图编辑器里的本地 OCR 结果窗口。
///
/// 关键约束：截图编辑器本身运行在 `.screenSaver` 层级（全屏遮罩），
/// 普通层级的窗口会被它整块盖住，用户只能看到“正在识别文字…”然后什么都没有。
/// 所以结果窗的层级必须由调用方显式设为“高于编辑器”，不能自己写死 `.floating`。
final class OCRResultWindowController: NSWindowController, NSWindowDelegate {
    private let image: NSImage
    private let recognizedText: String
    private let textView = OCRResultTextView(frame: .zero)
    private let selectionStatus = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let copySelectionButton = NSButton()
    private let copyAllButton = NSButton()
    var onClose: (() -> Void)?

    init(image: NSImage, text: String) {
        self.image = image
        recognizedText = text

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "提取文字"
        window.minSize = NSSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // 与截图编辑器一致的跨空间行为，避免窗口被放到非当前 Space 而“看不见”。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 调用方会临时把编辑器降到普通层级，这里只需常规浮动层级即可压在编辑器之上。
        window.level = .floating
        window.center()
        super.init(window: window)

        window.delegate = self
        configureView(in: window.contentView ?? NSView())
        // 布局装配完再收回设计尺寸并重新居中，任何内部固有尺寸都不该撑大窗口。
        window.setContentSize(NSSize(width: 900, height: 580))
        window.center()
        textView.onCancel = { [weak self] in self?.window?.close() }
    }

    required init?(coder: NSCoder) { nil }

    /// 截图编辑器在 screenSaver 层级时，直接开普通窗口会被整块盖住；
    /// 但把窗口抬到 1001 又会被窗口服务器拒绝（窗口显示“可见”却不在屏上）。
    /// 所以调用方先临时降低编辑器层级，这里保持标准 `.floating` 即可。

    func showAndActivate() {
        guard let window else { return }
        showWindow(nil)
        // 先激活应用，再抢 key：反过来的话，激活过程会把 key 还给原来的截图编辑器。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 截图会话里应用未必处于激活态，避免出现“窗口已创建但不在最前”的假死。
        window.orderFrontRegardless()
        window.makeFirstResponder(textView)
        // 激活是异步的，下一轮 runloop 再确认一次 key 与焦点。
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            window.makeKey()
            window.makeFirstResponder(self.textView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: - Layout

    private func configureView(in root: NSView) {
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let hasText = !recognizedText.isEmpty

        let subtitle = NSTextField(labelWithString: hasText
            ? "识别在本机完成，共 \(recognizedText.count) 字。在右侧框选任意文字后复制。"
            : "识别在本机完成；这张截图里没有识别到文字。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let previewLabel = sectionLabel("截图")
        let resultLabel = sectionLabel("识别结果")

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        // 预览图只按容器缩放，禁止用固有尺寸参与布局：
        // 一张 2880×1800 的截图会把整个结果窗顶成 5897×1958 并飞出屏幕。
        imageView.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        imageView.setContentCompressionResistancePriority(.init(rawValue: 1), for: .vertical)
        imageView.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        imageView.setContentHuggingPriority(.init(rawValue: 1), for: .vertical)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let previewBox = NSView()
        previewBox.wantsLayer = true
        // 用极淡的中性色界定预览区，不用描边，避免深色底图上出现一圈黑线。
        previewBox.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.10).cgColor
        previewBox.layer?.cornerRadius = 8
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(imageView)

        textView.string = recognizedText
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self

        let textScroll = NSScrollView()
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.hasVerticalScroller = true
        textScroll.documentView = textView
        textScroll.wantsLayer = true
        textScroll.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        textScroll.layer?.cornerRadius = 8
        textScroll.layer?.masksToBounds = true
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = "未识别到文字"
        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = hasText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        copySelectionButton.title = "复制所选文字"
        copySelectionButton.target = self
        copySelectionButton.action = #selector(copySelection(_:))
        copySelectionButton.bezelStyle = .rounded
        copySelectionButton.isEnabled = hasText
        copySelectionButton.translatesAutoresizingMaskIntoConstraints = false

        copyAllButton.title = "复制全文"
        copyAllButton.target = self
        copyAllButton.action = #selector(copyAll(_:))
        copyAllButton.bezelStyle = .rounded
        copyAllButton.keyEquivalent = hasText ? "\r" : ""
        copyAllButton.isEnabled = hasText
        copyAllButton.translatesAutoresizingMaskIntoConstraints = false

        selectionStatus.font = .systemFont(ofSize: 12)
        selectionStatus.textColor = .secondaryLabelColor
        selectionStatus.stringValue = hasText ? "可在右侧直接框选文字" : "换一个文字更清晰的选区再试一次"
        selectionStatus.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [selectionStatus, spacer, copySelectionButton, copyAllButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(subtitle)
        root.addSubview(previewLabel)
        root.addSubview(resultLabel)
        root.addSubview(previewBox)
        root.addSubview(divider)
        root.addSubview(textScroll)
        root.addSubview(emptyLabel)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            subtitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            previewLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            previewLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            resultLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 20),
            resultLabel.topAnchor.constraint(equalTo: previewLabel.topAnchor),

            previewBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            previewBox.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -20),
            previewBox.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 8),
            previewBox.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),

            imageView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -12),

            divider.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            divider.topAnchor.constraint(equalTo: previewBox.topAnchor),
            divider.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            textScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 20),
            textScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            textScroll.topAnchor.constraint(equalTo: resultLabel.bottomAnchor, constant: 8),
            textScroll.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: textScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: textScroll.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 28),

            previewBox.widthAnchor.constraint(equalTo: textScroll.widthAnchor)
        ])
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Actions

    @objc private func copySelection(_ sender: Any?) {
        let range = textView.selectedRange()
        guard range.length > 0 else {
            NSSound.beep()
            selectionStatus.stringValue = "请先在右侧选择需要复制的文字"
            return
        }
        let selected = (recognizedText as NSString).substring(with: range)
        copy(selected)
        selectionStatus.stringValue = "已复制所选 \(selected.count) 字"
    }

    @objc private func copyAll(_ sender: Any?) {
        guard !recognizedText.isEmpty else { return }
        copy(recognizedText)
        selectionStatus.stringValue = "已复制全文 \(recognizedText.count) 字"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([text as NSString])
    }

    // MARK: - Self test

    /// 把结果窗的真实内容渲染成 PNG，并用窗口服务器的前后顺序证明它压在编辑器之上。
    func autotestDump(to path: String, editorWindow: NSWindow?) -> String {
        guard let window, let content = window.contentView else { return "no-window" }
        content.layoutSubtreeIfNeeded()
        let size = content.bounds.size
        guard size.width > 1, size.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return "no-rep"
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }

        // CGWindowList 是从前到后的顺序：只有结果窗的序号更小，才算真正压在编辑器上面。
        let order = Self.onScreenWindowNumbers()
        let ocrIndex = order.firstIndex(of: window.windowNumber)
        let editorIndex = editorWindow.flatMap { order.firstIndex(of: $0.windowNumber) }
        let aboveEditor: Bool
        if let ocrIndex, let editorIndex {
            aboveEditor = ocrIndex < editorIndex
        } else {
            aboveEditor = false
        }
        let onScreen = window.occlusionState.contains(.visible)
        let own = Self.ownWindows()
        return "visible=\(window.isVisible) onscreen=\(onScreen) key=\(window.isKeyWindow) "
            + "level=\(window.level.rawValue) aboveEditor=\(aboveEditor) "
            + "size=\(Int(size.width))x\(Int(size.height)) frame=\(Int(window.frame.width))x\(Int(window.frame.height))@(\(Int(window.frame.minX)),\(Int(window.frame.minY))) "
            + "ocrNo=\(window.windowNumber) editorNo=\(editorWindow?.windowNumber ?? -1) "
            + "active=\(NSApp.isActive) ownWindows=\(own) "
            + "textChars=\(recognizedText.count) emptyHint=\(!emptyLabel.isHidden)"
    }

    /// 自测复制链路：按选区复制、复制全文都必须写入识别文本本身。
    func autotestCopyChecks() -> String {
        guard !recognizedText.isEmpty else { return "empty-text" }
        let nsText = recognizedText as NSString
        let sampleLength = min(6, nsText.length)
        let sample = nsText.substring(to: sampleLength)

        textView.setSelectedRange(NSRange(location: 0, length: sampleLength))
        copySelection(nil)
        let selectedPaste = NSPasteboard.general.string(forType: .string) ?? ""

        copyAll(nil)
        let allPaste = NSPasteboard.general.string(forType: .string) ?? ""

        let status = selectionStatus.stringValue
        return "selectedMatch=\(selectedPaste == sample) allMatch=\(allPaste == recognizedText) "
            + "chars=\(nsText.length) status=\(status)"
    }

    private static func onScreenWindowNumbers() -> [Int] {        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    /// 自测用：当前进程在窗口服务器里登记了哪些窗口（含层级与是否在屏）。
    private static func ownWindows() -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return "none"
        }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        return list.compactMap { info -> String? in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == pid,
                  let number = info[kCGWindowNumber as String] as? Int else { return nil }
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 0
            return "\(number):layer\(layer):on\(onscreen):a\(String(format: "%.2f", alpha))"
        }.joined(separator: ",")
    }
}

extension OCRResultWindowController: NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) {
        let count = textView.selectedRange().length
        selectionStatus.stringValue = count > 0 ? "已选择 \(count) 字" : "可在右侧直接框选文字"
    }
}

/// 只读结果文本：保留原生框选，Esc 直接关窗。
private final class OCRResultTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
