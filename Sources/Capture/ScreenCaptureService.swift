import Cocoa
import ScreenCaptureKit

/// 预热状态与缓存的持有者。
/// 锁只在同步方法里加：`NSLock.lock()` 标了 `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`，
/// 直接在 async 函数体里调用会一路警告到 Swift 6 变成编译错误。
private final class WarmCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: SCShareableContent?
    private var cachedAt: CFTimeInterval = 0
    private var prewarming = false
    private var lastPrewarmAt: CFTimeInterval = 0

    var content: SCShareableContent? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// true 表示本次预热可以启动；已有预热在跑、或刚预热过就跳过。
    func beginPrewarm() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if prewarming || CACurrentMediaTime() - lastPrewarmAt < 2 { return false }
        prewarming = true
        return true
    }

    /// 只更新缓存，不碰预热节流状态（截图路径重新枚举后回填用）。
    func store(_ content: SCShareableContent) {
        lock.lock(); defer { lock.unlock() }
        cached = content
        cachedAt = CACurrentMediaTime()
    }

    /// 缓存是否还能用。窗口列表会变，显示器也可能改分辨率/被拔掉，
    /// 放太久就重枚举一次（热态下也就几十毫秒，比截错屏便宜）。
    func isFresh(maxAge: CFTimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cached != nil && CACurrentMediaTime() - cachedAt < maxAge
    }

    func finishPrewarm(content: SCShareableContent?) {
        lock.lock(); defer { lock.unlock() }
        if let content {
            cached = content
            cachedAt = CACurrentMediaTime()
        }
        prewarming = false
        lastPrewarmAt = CACurrentMediaTime()
    }
}

/// 截屏主屏/指定屏。冷启动一次要 1s+，所以这里做了「预热 + 缓存」：
/// 常驻应用在空闲时先把 SCShareableContent 和抓图通道焐热，快捷键按下时只做一次像素抓取。
final class ScreenCaptureService {
    /// `SCShareableContent` 会把系统里所有窗口枚举一遍，冷态下光这一步就要几百毫秒。
    /// 缓存只存「显示器信息 + 应用列表」，不存任何像素，不涉及隐私留存。
    private let warmCache = WarmCache()

    var hasWarmCache: Bool { warmCache.content != nil }

    func snapshot(screen: NSScreen) async throws -> CaptureSnapshot {
        let started = CACurrentMediaTime()
        // NSScreen 不是 Sendable，但下面只在 MainActor 上读它的属性，跨线程传引用本身没有副作用。
        nonisolated(unsafe) let target = screen
        let info = await MainActor.run {
            ScreenInfo(displayID: Self.displayID(of: target),
                       scale: target.backingScaleFactor,
                       frame: target.frame,
                       name: target.localizedName)
        }

        let (display, content) = try await resolveDisplay(for: info.displayID)
        let resolvedAt = CACurrentMediaTime()

        // 关键：遮罩层会先挂在屏幕上等底图，抓图必须排除 PinSnap 自己的所有窗口，
        // 否则截图里会连遮罩、工具栏一起截进去。
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ownApplications(in: content),
                                     exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        // 尺寸按 NSScreen 的当前 frame × scale 算，而不是缓存的 display.width：
        // 显示器改过分辨率后缓存里仍是旧值，照抄会抓出错尺寸的图。
        configuration.width = max(1, Int(info.frame.width * info.scale))
        configuration.height = max(1, Int(info.frame.height * info.scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        // 日志里必须留着 scale=xxx：Scripts/verify-geometry.sh 靠它换算期望的像素偏移。
        NSLog("PinSnap: capture \(info.name) \(image.width)x\(image.height) scale=\(info.scale) "
              + "resolve=\(Self.ms(since: started))ms fetch=\(Self.ms(since: resolvedAt))ms "
              + "total=\(Self.ms(since: started))ms")
        return CaptureSnapshot(image: image,
                               pixelSize: CGSize(width: image.width, height: image.height),
                               screenFrame: info.frame,
                               scale: info.scale)
    }

    /// 预热：枚举一次可截内容，再跑一张极小的抓图。
    /// 抓图那一步不能省 —— `SCScreenshotManager` 与 WindowServer 的通道是首次调用才建立的，
    /// 只缓存窗口列表的话，第一次按快捷键仍然要等大半秒。
    /// 静默失败：没授过权时仅记日志，不弹任何窗，真正的错误提示留给用户主动截图那一刻。
    func prewarm() async {
        guard warmCache.beginPrewarm() else { return }
        let started = CACurrentMediaTime()
        var warmed: SCShareableContent?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            warmed = content
            let mainDisplayID = await MainActor.run { NSScreen.main.map { Self.displayID(of: $0) } }
            if let mainDisplayID,
               let display = content.displays.first(where: { $0.displayID == mainDisplayID }) {
                let configuration = SCStreamConfiguration()
                // 只要通道建立，像素多少无关，用小尺寸避免白占 GPU。
                configuration.width = 16
                configuration.height = 16
                configuration.showsCursor = false
                let filter = SCContentFilter(display: display,
                                             excludingApplications: ownApplications(in: content),
                                             exceptingWindows: [])
                _ = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                configuration: configuration)
            }
            NSLog("PinSnap: prewarm ok \(Self.ms(since: started))ms displays=\(content.displays.count)")
        } catch {
            NSLog("PinSnap: prewarm failed \(Self.ms(since: started))ms \(error)")
        }
        warmCache.finishPrewarm(content: warmed)
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

    /// 命中缓存就直接用；显示器被插拔过（displayID 对不上）就重新枚举一次。
    /// 只有精确匹配才复用缓存，避免双屏下随手拿 `displays.first` 截错屏。
    private func resolveDisplay(for displayID: CGDirectDisplayID) async throws -> (SCDisplay, SCShareableContent) {
        if warmCache.isFresh(maxAge: 300),
           let cached = warmCache.content,
           let display = cached.displays.first(where: { $0.displayID == displayID }) {
            return (display, cached)
        }
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        warmCache.store(fresh)
        guard let display = fresh.displays.first(where: { $0.displayID == displayID }) ?? fresh.displays.first else {
            throw CaptureError.noDisplay
        }
        return (display, fresh)
    }

    private func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        guard let ownBundleID = Bundle.main.bundleIdentifier else { return [] }
        return content.applications.filter { $0.bundleIdentifier == ownBundleID }
    }

    private func screenScale(containing frame: NSRect) -> CGFloat {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }

    static func ms(since start: CFTimeInterval) -> String {
        String(format: "%.1f", (CACurrentMediaTime() - start) * 1000)
    }

    private struct ScreenInfo {
        let displayID: CGDirectDisplayID
        let scale: CGFloat
        let frame: NSRect
        let name: String
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
