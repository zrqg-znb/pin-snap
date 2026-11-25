import Cocoa
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureCoordinator = CaptureCoordinator()
    private let pinController = PinController()
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
        captureCoordinator.onEditorPresented = { [weak self] in self?.hideMainWindowForCapture() }

        hotkeyController = HotkeyController { [weak self] in self?.beginRegionCapture(nil) }
        hotkeyController?.registerDefaultShortcut()
        MainWindowController.shared.showAndActivate()
        if SelfTest.isEnabled {
            MainWindowController.shared.window?.orderOut(nil)
            SelfTest.run(coordinator: captureCoordinator, service: ScreenCaptureService())
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func captureFullScreen(_ sender: Any?) { captureCoordinator.beginFullScreenCapture() }
    @objc private func captureRegion(_ sender: Any?) { beginRegionCapture(sender) }
    @objc private func captureWindow(_ sender: Any?) { captureCoordinator.chooseWindowCapture() }
    @objc private func showMainWindow(_ sender: Any?) { MainWindowController.shared.showAndActivate() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func beginRegionCapture(_ sender: Any?) {
        captureCoordinator.beginRegionCapture()
    }

    private func hideMainWindowForCapture() {
        guard let window = MainWindowController.shared.window else { return }
        mainWindowWasVisible = window.isVisible
        window.orderOut(nil)
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
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "退出 PinSnap", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
}
