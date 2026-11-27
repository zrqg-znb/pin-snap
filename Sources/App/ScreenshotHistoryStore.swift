import Cocoa

/// 纯本地截图历史：只保存用户完成（复制、保存或固定）的最终渲染图，
/// 不记录原始全屏底图、不上传网络，也不会保存可编辑标注工程。
///
/// 存储在 Application Support/PinSnap/History，下设 PNG 文件和 index.json。
/// 索引先安全写入，再做容量裁剪；读取失败时会忽略坏条目并在下一次写入时修复。
final class ScreenshotHistoryStore {
    struct Item: Codable, Identifiable, Equatable {
        let id: UUID
        let filename: String
        let createdAt: Date
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        var ocrText: String
        var ocrIndexed: Bool

        private enum CodingKeys: String, CodingKey {
            case id, filename, createdAt, pixelWidth, pixelHeight, byteCount, ocrText, ocrIndexed
        }

        init(id: UUID, filename: String, createdAt: Date, pixelWidth: Int, pixelHeight: Int, byteCount: Int, ocrText: String = "", ocrIndexed: Bool = false) {
            self.id = id
            self.filename = filename
            self.createdAt = createdAt
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.byteCount = byteCount
            self.ocrText = ocrText
            self.ocrIndexed = ocrIndexed
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            filename = try values.decode(String.self, forKey: .filename)
            createdAt = try values.decode(Date.self, forKey: .createdAt)
            pixelWidth = try values.decode(Int.self, forKey: .pixelWidth)
            pixelHeight = try values.decode(Int.self, forKey: .pixelHeight)
            byteCount = try values.decode(Int.self, forKey: .byteCount)
            // 兼容 1.2.0 OCR 上线前已有的 index.json。
            ocrText = try values.decodeIfPresent(String.self, forKey: .ocrText) ?? ""
            ocrIndexed = try values.decodeIfPresent(Bool.self, forKey: .ocrIndexed) ?? false
        }

        var fileURL: URL { ScreenshotHistoryStore.historyDirectory.appendingPathComponent(filename) }
    }

    static let shared = ScreenshotHistoryStore()

    static let maximumItemCount = 120
    static let maximumBytes = 512 * 1024 * 1024
    static let defaultRetentionDays = 30

    private struct Index: Codable {
        var version = 1
        var items: [Item]
    }

    private static let directoryName = "PinSnap"
    private static let historyDirectoryName = "History"
    private static let indexFilename = "index.json"

    static var historyDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(historyDirectoryName, isDirectory: true)
    }

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.pinsnap.history-store", qos: .utility)
    private var items: [Item] = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        queue.sync {
            ensureDirectory()
            items = loadIndex()
            pruneLocked(retentionDays: Self.defaultRetentionDays)
            scheduleOCRForUnindexedItemsLocked()
        }
    }

    var allItems: [Item] {
        queue.sync { items }
    }

    var totalBytes: Int {
        queue.sync { items.reduce(0) { $0 + $1.byteCount } }
    }

    /// 匹配已识别的本地文本。没有关键词时返回完整历史；OCR 尚在后台完成的条目会显示为“正在识别”。
    func search(_ query: String) -> [Item] {
        let normalized = Self.normalized(query)
        return queue.sync {
            guard !normalized.isEmpty else { return items }
            return items.filter { Self.normalized($0.ocrText).contains(normalized) }
        }
    }

    var ocrPendingCount: Int {
        queue.sync { items.filter { !$0.ocrIndexed }.count }
    }

    /// 在后台编码和落盘，避免导出一张大 Retina PNG 时阻塞编辑器关闭动画。
    func add(_ image: NSImage, completion: ((Result<Item, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let item = try self.addLocked(image)
                DispatchQueue.main.async { completion?(.success(item)) }
            } catch {
                NSLog("PinSnap history: save failed \(error)")
                DispatchQueue.main.async { completion?(.failure(error)) }
            }
        }
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        queue.sync {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
            let item = items.remove(at: index)
            try? fileManager.removeItem(at: item.fileURL)
            writeIndexLocked()
            return true
        }
    }

    @discardableResult
    func clearAll() -> Int {
        queue.sync {
            let closing = items
            closing.forEach { try? fileManager.removeItem(at: $0.fileURL) }
            items.removeAll()
            writeIndexLocked()
            return closing.count
        }
    }

    /// 历史窗口读取图片时使用。条目在另一处被裁剪后会返回 nil，而不是崩溃。
    func image(for item: Item) -> NSImage? {
        queue.sync {
            guard items.contains(where: { $0.id == item.id }) else { return nil }
            return NSImage(contentsOf: item.fileURL)
        }
    }

    /// 可被未来设置页调用；当前保留默认 30 天，同时依然受条数和空间预算约束。
    func prune(retentionDays: Int = defaultRetentionDays) {
        queue.async { [weak self] in self?.pruneLocked(retentionDays: retentionDays) }
    }

    @discardableResult
    func selfTestInsert(_ image: NSImage) -> Result<Item, Error> {
        queue.sync { Result { try addLocked(image) } }
    }

    func selfTestRecognize(_ image: NSImage) -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "invalid-image" }
        return TextRecognitionService.recognizeText(in: cgImage)
    }

    func selfTestReset() {
        _ = clearAll()
    }

    private func addLocked(_ image: NSImage) throws -> Item {
        ensureDirectory()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw HistoryError.invalidImage
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw HistoryError.pngEncodingFailed
        }
        let item = Item(id: UUID(),
                        filename: "\(UUID().uuidString).png",
                        createdAt: Date(),
                        pixelWidth: cgImage.width,
                        pixelHeight: cgImage.height,
                        byteCount: png.count)
        try png.write(to: item.fileURL, options: .atomic)
        items.insert(item, at: 0)
        writeIndexLocked()
        scheduleOCR(for: item)
        pruneLocked(retentionDays: Self.defaultRetentionDays)
        return item
    }

    private func scheduleOCRForUnindexedItemsLocked() {
        for item in items where !item.ocrIndexed {
            scheduleOCR(for: item)
        }
    }

    /// Vision 在本机进程内执行，不发起网络请求。OCR 失败也标记为已处理，避免每次启动重复消耗资源。
    private func scheduleOCR(for item: Item) {
        guard fileManager.fileExists(atPath: item.fileURL.path) else { return }
        let itemID = item.id
        let url = item.fileURL
        queue.async { [weak self] in
            guard let self else { return }
            let text = Self.recognizeText(at: url)
            guard let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
            self.items[index].ocrText = text
            self.items[index].ocrIndexed = true
            self.writeIndexLocked()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .pinSnapHistoryOCRDidUpdate, object: self, userInfo: ["itemID": itemID])
            }
        }
    }

    private static func recognizeText(at url: URL) -> String {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        return TextRecognitionService.recognizeText(in: cgImage)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private func ensureDirectory() {
        do {
            try fileManager.createDirectory(at: Self.historyDirectory,
                                            withIntermediateDirectories: true)
        } catch {
            NSLog("PinSnap history: cannot create directory \(error)")
        }
    }

    private func loadIndex() -> [Item] {
        let url = Self.historyDirectory.appendingPathComponent(Self.indexFilename)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(Index.self, from: data) else {
            return []
        }
        return index.items.filter { item in
            fileManager.fileExists(atPath: item.fileURL.path)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func writeIndexLocked() {
        ensureDirectory()
        let url = Self.historyDirectory.appendingPathComponent(Self.indexFilename)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Index(items: items))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("PinSnap history: write index failed \(error)")
        }
    }

    private func pruneLocked(retentionDays: Int) {
        ensureDirectory()
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, retentionDays), to: Date()) ?? .distantPast
        var retained = items.filter { item in
            guard item.createdAt >= cutoff, fileManager.fileExists(atPath: item.fileURL.path) else {
                try? fileManager.removeItem(at: item.fileURL)
                return false
            }
            return true
        }

        var total = retained.reduce(0) { $0 + $1.byteCount }
        while retained.count > Self.maximumItemCount || total > Self.maximumBytes {
            guard let last = retained.popLast() else { break }
            total -= last.byteCount
            try? fileManager.removeItem(at: last.fileURL)
        }
        items = retained
        writeIndexLocked()
    }

    enum HistoryError: LocalizedError {
        case invalidImage
        case pngEncodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取截图像素数据"
            case .pngEncodingFailed: return "无法编码 PNG"
            }
        }
    }
}
