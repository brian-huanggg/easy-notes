import Foundation

/// 每種檔案類型的核心行為。核心層（Vault、Index、Sync）只透過這個協定認識檔案類型。
/// 編輯器由 App 層依 `id` 對應（見 App/Editors/EditorRegistry.swift），讓核心保持無 UI 相依、可單元測試。
public protocol DocumentKind {
    static var id: String { get }
    /// 完整副檔名（不含前導點），例如 "md"、"excalidraw"
    static var fileExtensions: [String] { get }
    /// 新建檔案的預設內容
    static func template(title: String) -> Data
    /// 抽出搜尋、連結、標籤等索引資訊
    static func index(_ data: Data, fileName: String) -> IndexEntry
    /// 三方合併；回傳 nil 代表無法合併，由同步層產生衝突副本
    static func merge(base: Data?, local: Data, remote: Data) -> Data?
}

public struct IndexEntry: Equatable, Sendable {
    public var title: String
    public var plainText: String
    public var links: [String]
    public var tags: [String]

    public init(title: String, plainText: String, links: [String] = [], tags: [String] = []) {
        self.title = title
        self.plainText = plainText
        self.links = links
        self.tags = tags
    }
}

public enum DocumentKinds {
    nonisolated(unsafe) public static let all: [any DocumentKind.Type] = [MarkdownKind.self, InkKind.self]

    public static func kind(for url: URL) -> (any DocumentKind.Type)? {
        let name = url.lastPathComponent.lowercased()
        return all.first { kind in
            kind.fileExtensions.contains { name.hasSuffix("." + $0) }
        }
    }
}

extension DocumentKind {
    /// 沒有特定合併策略時：內容相同即視為已合併，否則交給衝突副本
    public static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        local == remote ? local : nil
    }
}
