import Foundation
import SwiftUI

/// 列表卡片縮圖的資料。由外掛在背景從檔案內容產生，依內容 hash 快取，所以只放可序列化的值。
/// `image` 不進 JSON：快取另存成同名的 `.png`，JSON 只記錄有沒有圖。
public struct DocumentPreview: Codable, Hashable, Sendable {
    public var title: String?
    /// 標題之後的前幾行（已去掉語法）
    public var lines: [String]
    /// 圖形類外掛（白板）畫好的縮圖 PNG；也用於 `![[x]]` 嵌入（`embed://`）
    public var image: Data?

    public init(title: String? = nil, lines: [String] = [], image: Data? = nil) {
        self.title = title
        self.lines = lines
        self.image = image
    }

    private enum CodingKeys: String, CodingKey {
        case title, lines, hasImage
    }

    /// 快取 JSON 中是否有對應的 PNG（`image` 本身由 `PreviewCache` 另外讀寫）
    public private(set) var hasImage = false

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        hasImage = try c.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(lines, forKey: .lines)
        if image != nil || hasImage { try c.encode(true, forKey: .hasImage) }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.lines == b.lines && a.image == b.image
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(lines)
        hasher.combine(image)
    }
}

/// 外掛以 `addPreview(for:_:)` 註冊的縮圖。原生渲染，不開 WebView。
/// `makePreview` 在背景執行緒呼叫，結果會被快取；`view` 在主執行緒把快取的資料畫成縮圖。
public protocol DocumentPreviewProvider: Sendable {
    /// 產生方式改變時遞增，舊快取就不再使用
    var version: Int { get }
    func makePreview(_ data: Data) -> DocumentPreview
    /// `scale`：Desktop 卡片 1、Mobile Pin Card 約 0.7
    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView
}

public extension DocumentPreviewProvider {
    var version: Int { 1 }
}

/// 預覽快取：記憶體 → `<directory>/<kind>-v<version>/<hash>.json`（+ `<hash>.png`）→ 重新產生。
/// 檔案未變（hash 相同）就不重算；快取資料夾可以整個刪掉，之後會重新產生出相同的結果。
/// 記憶體只保留 JSON 的部分；PNG 另有依大小限制的快取，列表捲過上千個檔案也不會把圖都留在記憶體。
public actor PreviewCache {
    private let directory: URL
    private var memory: [String: DocumentPreview] = [:]
    private var order: [String] = []
    private let memoryLimit: Int
    private let images = NSCache<NSString, NSData>()

    /// 通常是 `<vault>/.easynotes/cache/preview`（cache 不參與同步）
    public init(directory: URL, memoryLimit: Int = 2000, imageMemoryLimit: Int = 32 << 20) {
        self.directory = directory
        self.memoryLimit = memoryLimit
        images.totalCostLimit = imageMemoryLimit
    }

    /// `load` 只在快取沒有時才呼叫（讀檔）
    public func preview(kindID: String, hash: String, provider: any DocumentPreviewProvider,
                        load: @Sendable () throws -> Data) -> DocumentPreview? {
        let folder = "\(kindID)-v\(provider.version)"
        let key = "\(folder)/\(hash)"
        let url = directory.appending(path: folder, directoryHint: .isDirectory).appending(path: "\(hash).json")
        let pngURL = url.deletingPathExtension().appendingPathExtension("png")

        if let cached = memory[key] ?? readJSON(url, key: key) {
            guard cached.hasImage else { return cached }
            if let image = image(key: key, url: pngURL) {
                var full = cached
                full.image = image
                return full
            }
            // PNG 被刪掉：往下重新產生
        }
        guard let content = try? load() else { return nil }
        let preview = provider.makePreview(content)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 先寫 PNG 再寫 JSON：JSON 說有圖時圖一定在
        if let image = preview.image {
            try? image.write(to: pngURL, options: .atomic)
            images.setObject(image as NSData, forKey: key as NSString, cost: image.count)
        }
        if let json = try? JSONEncoder().encode(preview) {
            try? json.write(to: url, options: .atomic)
            if let stored = try? JSONDecoder().decode(DocumentPreview.self, from: json) { remember(stored, for: key) }
        }
        return preview
    }

    private func readJSON(_ url: URL, key: String) -> DocumentPreview? {
        guard let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(DocumentPreview.self, from: data)
        else { return nil }
        remember(cached, for: key)
        return cached
    }

    private func image(key: String, url: URL) -> Data? {
        if let cached = images.object(forKey: key as NSString) { return cached as Data }
        guard let data = try? Data(contentsOf: url) else { return nil }
        images.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    private func remember(_ preview: DocumentPreview, for key: String) {
        if memory[key] == nil { order.append(key) }
        memory[key] = preview
        if order.count > memoryLimit {
            memory[order.removeFirst()] = nil
        }
    }
}
