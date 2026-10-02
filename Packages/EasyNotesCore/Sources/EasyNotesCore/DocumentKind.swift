import Foundation

/// 每種檔案類型的核心行為。核心層（Vault、Index、Sync）只透過這個協定認識檔案類型。
/// 實作放在各外掛；編輯器由外掛向 EasyNotesUI 的 PluginRegistry 註冊，讓核心保持無 UI 相依、可單元測試。
public protocol DocumentKind: SendableMetatype {
    static var id: String { get }
    /// 完整副檔名（不含前導點），例如 "md"、"excalidraw"
    static var fileExtensions: [String] { get }
    /// 新建檔案的預設內容
    static func template(title: String) -> Data
    /// 抽出搜尋、連結、標籤等索引資訊
    static func index(_ data: Data, fileName: String) -> IndexEntry
    /// 三方合併；回傳 nil 代表無法合併，由同步層產生衝突副本
    static func merge(base: Data?, local: Data, remote: Data) -> Data?
    /// 筆記改名時更新內容中指向它的連結；回傳 nil 代表沒有要改的
    static func renameLinks(in data: Data, from oldName: String, to newName: String) -> Data?
    /// 設定或取消釘選，其餘內容不變；回傳 nil 代表這個類型不支援釘選
    static func setPinned(_ pinned: Bool, in data: Data) -> Data?
}

/// `icon`、`pinned`、`summary` 由外掛決定，Core 只存不解讀
public struct IndexEntry: Equatable, Sendable {
    public var title: String
    public var plainText: String
    public var links: [String]
    public var tags: [String]
    /// 文件圖示（例如 frontmatter 的 emoji）
    public var icon: String?
    public var pinned: Bool
    /// 列表卡片副標的一行摘要，例如「1,240 字」
    public var summary: String?

    public init(title: String, plainText: String, links: [String] = [], tags: [String] = [],
                icon: String? = nil, pinned: Bool = false, summary: String? = nil) {
        self.title = title
        self.plainText = plainText
        self.links = links
        self.tags = tags
        self.icon = icon
        self.pinned = pinned
        self.summary = summary
    }
}

/// 啟動時由外掛組成的檔案類型表；之後不再變動，可在任何執行緒使用。
public struct KindRegistry: Sendable {
    public enum RegistrationError: Error, Equatable {
        case duplicateExtension(String)
    }

    public let all: [any DocumentKind.Type]

    /// 同一個副檔名只能屬於一個 Kind
    public init(_ kinds: [any DocumentKind.Type]) throws {
        var seen = Set<String>()
        for ext in kinds.flatMap({ $0.fileExtensions }) {
            guard seen.insert(ext.lowercased()).inserted else { throw RegistrationError.duplicateExtension(ext) }
        }
        all = kinds
    }

    public func kind(for path: String) -> (any DocumentKind.Type)? {
        let name = (path as NSString).lastPathComponent.lowercased()
        return all.first { kind in
            kind.fileExtensions.contains { name.hasSuffix("." + $0.lowercased()) }
        }
    }

    public func kind(for url: URL) -> (any DocumentKind.Type)? {
        kind(for: url.lastPathComponent)
    }

    public func kind(id: String) -> (any DocumentKind.Type)? {
        all.first { $0.id == id }
    }

    /// 去掉已註冊的副檔名，例如 "a/筆記.md" → "筆記"
    public func displayName(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        while !(name as NSString).pathExtension.isEmpty,
              all.contains(where: { $0.fileExtensions.contains((name as NSString).pathExtension.lowercased()) }) {
            name = (name as NSString).deletingPathExtension
        }
        return name
    }
}

extension DocumentKind {
    /// 沒有特定合併策略時：內容相同即視為已合併，否則交給衝突副本
    public static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        local == remote ? local : nil
    }

    public static func renameLinks(in data: Data, from oldName: String, to newName: String) -> Data? {
        nil
    }

    public static func setPinned(_ pinned: Bool, in data: Data) -> Data? {
        nil
    }

    /// 是否支援釘選（列表的釘選選單只對支援的類型顯示）
    public static var supportsPinning: Bool {
        setPinned(true, in: template(title: "")) != nil
    }
}
