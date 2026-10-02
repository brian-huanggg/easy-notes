import Foundation
import SwiftUI

/// 列表卡片縮圖的資料。由外掛在背景從檔案內容產生，依內容 hash 快取成 JSON，所以只放可序列化的值。
public struct DocumentPreview: Codable, Hashable, Sendable {
    public var title: String?
    /// 標題之後的前幾行（已去掉語法）
    public var lines: [String]

    public init(title: String? = nil, lines: [String] = []) {
        self.title = title
        self.lines = lines
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

/// 預覽快取：記憶體 → `<directory>/<kind>-v<version>/<hash>.json` → 重新產生。
/// 檔案未變（hash 相同）就不重算；快取資料夾可以整個刪掉，之後會重新產生出相同的結果。
public actor PreviewCache {
    private let directory: URL
    private var memory: [String: DocumentPreview] = [:]
    private var order: [String] = []
    private let memoryLimit: Int

    /// 通常是 `<vault>/.easynotes/cache/preview`（cache 不參與同步）
    public init(directory: URL, memoryLimit: Int = 2000) {
        self.directory = directory
        self.memoryLimit = memoryLimit
    }

    /// `load` 只在快取沒有時才呼叫（讀檔）
    public func preview(kindID: String, hash: String, provider: any DocumentPreviewProvider,
                        load: @Sendable () throws -> Data) -> DocumentPreview? {
        let folder = "\(kindID)-v\(provider.version)"
        let key = "\(folder)/\(hash)"
        if let cached = memory[key] { return cached }

        let url = directory.appending(path: folder, directoryHint: .isDirectory).appending(path: "\(hash).json")
        if let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(DocumentPreview.self, from: data) {
            remember(cached, for: key)
            return cached
        }
        guard let content = try? load() else { return nil }
        let preview = provider.makePreview(content)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(preview).write(to: url, options: .atomic)
        remember(preview, for: key)
        return preview
    }

    private func remember(_ preview: DocumentPreview, for key: String) {
        memory[key] = preview
        order.append(key)
        if order.count > memoryLimit {
            memory[order.removeFirst()] = nil
        }
    }
}
