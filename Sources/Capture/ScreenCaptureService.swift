import Cocoa
import ScreenCaptureKit

final class ScreenCaptureService {
    func snapshot(screen: NSScreen) async throws -> CaptureSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = display(for: screen, in: content) else { throw CaptureError.noDisplay }
        let scale = screen.backingScaleFactor
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(CGFloat(display.width) * scale))
        configuration.height = max(1, Int(CGFloat(display.height) * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        NSLog("PinSnap: screen=\(screen.localizedName) frame=\(screen.frame.size) scale=\(scale) scDisplay=\(display.width)x\(display.height) config=\(configuration.width)x\(configuration.height) image=\(image.width)x\(image.height)")
        return CaptureSnapshot(image: image,
                               pixelSize: CGSize(width: image.width, height: image.height),
                               screenFrame: screen.frame,
                               scale: scale)
    }

    func listCapturableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            return window.isOnScreen
                && app.bundleIdentifier != ownBundleID
                && window.frame.width >= 80
                && window.frame.height >= 60
                && window.windowLayer == 0
        }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }

    func capture(window: SCWindow) async throws -> NSImage {
        let scale = screenScale(containing: window.frame)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSImage(cgImage: image, size: window.frame.size)
    }

    private func screenScale(containing frame: NSRect) -> CGFloat {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return content.displays.first { $0.displayID == displayID } ?? content.displays.first
    }
}

enum CaptureError: LocalizedError {
    case noDisplay, noWindow, invalidRegion

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "找不到可用显示器。"
        case .noWindow: return "找不到可截取的窗口。"
        case .invalidRegion: return "选择的区域不在当前显示器内。"
        }
    }
}
