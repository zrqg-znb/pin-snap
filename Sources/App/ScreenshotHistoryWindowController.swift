import Cocoa

extension Notification.Name {
    static let pinSnapHistoryOCRDidUpdate = Notification.Name("PinSnap.historyOCRDidUpdate")
}

/// 单机历史浏览器：展示的是已经完成交付的最终 PNG，不读剪贴板，不扫描用户目录。
/// 每条记录都可再次复制、固定或删除；所有操作只在本机完成。
final class ScreenshotHistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ScreenshotHistoryStore
    private let onPin: (NSImage) -> Int
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "还没有历史截图\n完成一次复制、保存或固定后，最终图片会自动保存在这里。")
    private var items: [ScreenshotHistoryStore.Item] = []
    private var notificationToken: NSObjectProtocol?

    init(store: ScreenshotHistoryStore, onPin: @escaping (NSImage) -> Int) {
        self.store = store
        self.onPin = onPin

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        let window = NSWindow(contentRect: root.bounds,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "截图历史"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 580, height: 380)
        window.contentView = root
        super.init(window: window)

        configureView(in: root)
        notificationToken = NotificationCenter.default.addObserver(forName: .pinSnapHistoryOCRDidUpdate,
                                                                    object: store,
                                                                    queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
    }

    func showAndActivate() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureView(in root: NSView) {
        let title = NSTextField(labelWithString: "截图历史与本地文字搜索")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "清空历史", target: self, action: #selector(clearAll(_:)))
        clear.bezelStyle = .rounded
        clear.contentTintColor = .systemRed
        clear.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [title, NSView(), countLabel, clear])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        header.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let hint = NSTextField(wrappingLabelWithString: "复制、保存或固定后的最终图片会显示在这里。文字识别与搜索完全在本机完成；识别中的记录会显示进度。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "搜索截图中的文字"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let searchRow = NSStackView(views: [searchField])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.width = 700
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 78
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.selectionHighlightStyle = .none
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(hint)
        root.addSubview(searchRow)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            searchRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            searchRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            searchRow.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
    }

    private func reload() {
        items = store.search(searchField.stringValue)
        let megabytes = Double(store.totalBytes) / 1_048_576
        let pending = store.ocrPendingCount
        countLabel.stringValue = pending > 0
            ? "\(items.count) 张 · \(String(format: "%.1f", megabytes)) MB · 正在识别 \(pending) 张"
            : "\(items.count) 张 · \(String(format: "%.1f", megabytes)) MB"
        emptyLabel.stringValue = searchField.stringValue.isEmpty
            ? "还没有历史截图\n完成一次复制、保存或固定后，最终图片会自动保存在这里。"
            : "没有匹配的截图\n试试其他关键词。"
        emptyLabel.isHidden = !items.isEmpty
        table.isHidden = items.isEmpty
        table.reloadData()
    }

    @objc private func searchChanged(_ sender: Any?) {
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("history-item")
        let view: HistoryItemView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryItemView {
            view = reused
        } else {
            view = HistoryItemView()
            view.identifier = identifier
        }
        let item = items[row]
        view.configure(item: item, image: store.image(for: item))
        view.onCopy = { [weak self] in self?.copy(item) }
        view.onPin = { [weak self] in self?.pin(item) }
        view.onDelete = { [weak self] in self?.delete(item) }
        return view
    }

    @objc private func clearAll(_ sender: Any?) {
        guard !items.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空全部截图历史？"
        alert.informativeText = "将移除本机保存的 \(items.count) 张历史截图。此操作不会影响已导出的文件、剪贴板或桌面贴图。"
        alert.addButton(withTitle: "清空历史")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = store.clearAll()
        reload()
    }

    private func copy(_ item: ScreenshotHistoryStore.Item) {
        guard let image = store.image(for: item) else { reload(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        NSSound.beep()
    }

    private func pin(_ item: ScreenshotHistoryStore.Item) {
        guard let image = store.image(for: item) else { reload(); return }
        let evicted = onPin(image)
        if evicted > 0 {
            window?.title = "截图历史 · 已固定，自动关闭最早的 \(evicted) 张贴图"
        }
    }

    private func delete(_ item: ScreenshotHistoryStore.Item) {
        _ = store.remove(id: item.id)
        reload()
    }
}

private final class HistoryItemView: NSTableCellView {
    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var onDelete: (() -> Void)?

    private let thumbnail = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 5
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.borderWidth = 1
        thumbnail.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [titleLabel, metaLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false

        let copy = button(symbol: "doc.on.doc", tooltip: "复制")
        copy.action = #selector(copy(_:))
        let pin = button(symbol: "pin", tooltip: "固定到桌面")
        pin.action = #selector(pin(_:))
        let delete = button(symbol: "trash", tooltip: "从历史中删除")
        delete.contentTintColor = .systemRed
        delete.action = #selector(delete(_:))
        let actions = NSStackView(views: [copy, pin, delete])
        actions.orientation = .horizontal
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumbnail)
        addSubview(labels)
        addSubview(actions)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 92),
            thumbnail.heightAnchor.constraint(equalToConstant: 60),
            labels.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(item: ScreenshotHistoryStore.Item, image: NSImage?) {
        thumbnail.image = image
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM月dd日 HH:mm"
        titleLabel.stringValue = formatter.string(from: item.createdAt)
        let megabytes = Double(item.byteCount) / 1_048_576
        metaLabel.stringValue = "\(item.pixelWidth) × \(item.pixelHeight) · \(String(format: "%.1f", megabytes)) MB"
    }

    private func button(symbol: String, tooltip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: nil)
        button.image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: tooltip)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func copy(_ sender: Any?) { onCopy?() }
    @objc private func pin(_ sender: Any?) { onPin?() }
    @objc private func delete(_ sender: Any?) { onDelete?() }
}
