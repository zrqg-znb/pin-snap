import Cocoa
import CoreGraphics

extension Notification.Name {
    static let pinSnapCaptureFullScreen = Notification.Name("PinSnap.captureFullScreen")
    static let pinSnapCaptureRegion = Notification.Name("PinSnap.captureRegion")
    static let pinSnapCaptureWindow = Notification.Name("PinSnap.captureWindow")
    static let pinSnapRequestScreenPermission = Notification.Name("PinSnap.requestScreenPermission")
}

final class MainWindowController: NSWindowController {
    static let shared = MainWindowController()

    private init() {
        let view = MainView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "PinSnap"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        window.contentView = view
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class MainView: NSView {
    private let permissionStatus = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "PinSnap")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "截图、标注、复制、保存，并将重要内容固定在桌面之上。\n截图历史会在本机保存最终图片，并自动识别图片文字，可在“截图历史与文字搜索”中按文字找图。")
        subtitle.textColor = .secondaryLabelColor
        permissionStatus.font = .systemFont(ofSize: 13)
        permissionStatus.maximumNumberOfLines = 2
        updatePermissionStatus()

        let full = actionButton("全屏截图", symbol: "rectangle.inset.filled", action: #selector(captureFullScreen(_:)))
        let region = actionButton("区域截图", symbol: "selection.pin.in.out", action: #selector(captureRegion(_:)))
        let window = actionButton("窗口截图", symbol: "macwindow", action: #selector(captureWindow(_:)))
        let grid = NSGridView(views: [[full, region, window]])
        grid.rowSpacing = 0
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        [full, region, window].forEach { $0.widthAnchor.constraint(equalToConstant: 180).isActive = true }
        [full, region, window].forEach { $0.heightAnchor.constraint(equalToConstant: 80).isActive = true }

        let shortcutTitle = NSTextField(labelWithString: "快捷键")
        shortcutTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let shortcutInfo = NSTextField(wrappingLabelWithString: "区域截图：Command + Shift + 2\n这是系统级快捷键，不需要“输入监控”权限；若与其他软件冲突，请直接使用上方区域截图按钮。")
        shortcutInfo.textColor = .secondaryLabelColor
        let permissionButton = NSButton(title: "打开屏幕录制设置", target: self, action: #selector(requestScreenPermission(_:)))
        permissionButton.bezelStyle = .rounded
        let refreshButton = NSButton(title: "刷新权限状态", target: self, action: #selector(refreshPermission(_:)))
        refreshButton.bezelStyle = .rounded
        let permissionButtons = NSStackView(views: [permissionButton, refreshButton])
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8

        let historyHint = NSTextField(wrappingLabelWithString: "本地文字搜索入口：从菜单栏 PinSnap 图标或应用菜单打开“截图历史与文字搜索…”，在顶部“搜索截图中的文字”中检索；识别全程在本机完成。")
        historyHint.textColor = .secondaryLabelColor
        historyHint.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, subtitle, grid, separator(), shortcutTitle, shortcutInfo, historyHint, permissionStatus, permissionButtons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -34),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -28)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func actionButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageAbove
        button.font = .systemFont(ofSize: 14, weight: .medium)
        button.bezelStyle = .texturedRounded
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 600).isActive = true
        return box
    }

    @objc private func captureFullScreen(_ sender: Any?) { NotificationCenter.default.post(name: .pinSnapCaptureFullScreen, object: nil) }
    @objc private func captureRegion(_ sender: Any?) { NotificationCenter.default.post(name: .pinSnapCaptureRegion, object: nil) }
    @objc private func captureWindow(_ sender: Any?) { NotificationCenter.default.post(name: .pinSnapCaptureWindow, object: nil) }

    @objc private func requestScreenPermission(_ sender: Any?) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshPermission(_ sender: Any?) { updatePermissionStatus() }

    private func updatePermissionStatus() {
        permissionStatus.stringValue = "权限状态会在实际截图时由系统验证；如失败，弹窗会显示准确的错误域、错误码和当前应用路径。"
        permissionStatus.textColor = .secondaryLabelColor
    }
}
