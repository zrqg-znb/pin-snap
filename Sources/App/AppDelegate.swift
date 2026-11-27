import Cocoa
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureCoordinator = CaptureCoordinator()
    private let pinController = PinController()
    private let historyStore = ScreenshotHistoryStore.shared
    private lazy var historyWindowController = ScreenshotHistoryWindowController(
        store: historyStore,
        onPin: { [weak self] image in
            self?.pinController.pin(image) ?? 0
        }
    )
    private var statusItem: NSStatusItem?
    private var hotkeyController: HotkeyController?
    private var tokens: [NSObjectProtocol] = []
    private var mainWindowWasVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 与 main.swift 保持一致：菜单栏常驻应用，不在 Dock 里占位。
        NSApp.setActivationPolicy(.accessory)
        installActions()
        configureMainMenu()
        configureMenuBar()

        captureCoordinator.pinController = pinController
        captureCoordinator.historyStore = historyStore
        captureCoordinator.onEditorPresented = { [weak self] in self?.hideMainWindowForCapture() }
        captureCoordinator.onEditorClosed = { [weak self] in self?.restoreMainWindowAfterCapture() }

        hotkeyController = HotkeyController { [weak self] in self?.beginRegionCapture(nil) }
        hotkeyController?.registerDefaultShortcut()
        MainWindowController.shared.showAndActivate()
        if SelfTest.isEnabled {
            MainWindowController.shared.window?.orderOut(nil)
            SelfTest.run(coordinator: captureCoordinator, service: ScreenCaptureService())
        } else {
            // 菜单栏常驻，不缺这点空闲：启动稳定后先把抓图通道焐热。
            // 不预热的话第一次按快捷键要干等 ScreenCaptureKit 冷启动 1s 上下。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.captureCoordinator.prewarmCapture()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func captureFullScreen(_ sender: Any?) { captureCoordinator.beginFullScreenCapture() }
    @objc private func captureRegion(_ sender: Any?) { beginRegionCapture(sender) }
    @objc private func captureWindow(_ sender: Any?) { captureCoordinator.chooseWindowCapture() }
    @objc private func closeAllPins(_ sender: Any?) {
        let closed = pinController.closeAll()
        if closed == 0 {
            NSSound.beep()
        }
    }
    @objc private func showMainWindow(_ sender: Any?) { MainWindowController.shared.showAndActivate() }
    @objc private func showHistory(_ sender: Any?) { historyWindowController.showAndActivate() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func beginRegionCapture(_ sender: Any?) {
        captureCoordinator.beginRegionCapture()
    }

    private func hideMainWindowForCapture() {
        guard let window = MainWindowController.shared.window else { return }
        // 编辑器仍在展示时再次触发截图，主窗口已经被隐藏；保留首次抓图前的可见状态。
        mainWindowWasVisible = mainWindowWasVisible || window.isVisible
        window.orderOut(nil)
    }

    private func restoreMainWindowAfterCapture() {
        guard mainWindowWasVisible else { return }
        mainWindowWasVisible = false
        MainWindowController.shared.showAndActivate()
    }

    private func installActions() {
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: .pinSnapCaptureFullScreen, object: nil, queue: .main) { [weak self] _ in self?.captureFullScreen(nil) },
            center.addObserver(forName: .pinSnapCaptureRegion, object: nil, queue: .main) { [weak self] _ in self?.beginRegionCapture(nil) },
            center.addObserver(forName: .pinSnapCaptureWindow, object: nil, queue: .main) { [weak self] _ in self?.captureWindow(nil) }
        ]
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let button = item.button
        button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PinSnap")
        button?.toolTip = "PinSnap"
        let menu = NSMenu()
        let region = menu.addItem(withTitle: "区域截图（⌘⇧2）", action: #selector(captureRegion(_:)), keyEquivalent: "")
        let full = menu.addItem(withTitle: "全屏截图", action: #selector(captureFullScreen(_:)), keyEquivalent: "")
        let window = menu.addItem(withTitle: "窗口截图", action: #selector(captureWindow(_:)), keyEquivalent: "")
        [region, full, window].forEach { $0.target = self }
        menu.addItem(.separator())
        let history = menu.addItem(withTitle: "截图历史与文字搜索…", action: #selector(showHistory(_:)), keyEquivalent: "")
        history.target = self
        history.toolTip = "本机截图历史；在顶部搜索框直接检索截图中的文字"
        let closePins = menu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllPins(_:)), keyEquivalent: "")
        closePins.target = self
        menu.addItem(.separator())
        let main = menu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        main.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 PinSnap", action: #selector(quit(_:)), keyEquivalent: "")
        quitItem.target = self
        item.menu = menu
        statusItem = item
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "PinSnap")
        let showItem = appMenu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        showItem.target = self
        let history = appMenu.addItem(withTitle: "截图历史与文字搜索…", action: #selector(showHistory(_:)), keyEquivalent: "")
        history.target = self
        history.toolTip = "本机截图历史；在顶部搜索框直接检索截图中的文字"
        let closePins = appMenu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllPins(_:)), keyEquivalent: "")
        closePins.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "退出 PinSnap", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
}
