import Foundation

/// 外殼的目前位置：側邊欄選取、內容區顯示、上一頁 / 下一頁的歷史都用它
enum Route: Hashable, Codable {
    case all
    case recents
    case pinned
    /// Vault 內的資料夾（Spaces = 第一層資料夾）
    case folder(String)
    case tag(String)
    case file(String)
    /// 外掛以 `addPanel` 註冊的側邊欄項目
    case panel(String)

    var filePath: String? {
        if case .file(let path) = self { path } else { nil }
    }

    /// 改名或搬移 `from` 後，指向它（或其下）的位置改為 `to`
    func moved(from: String, to: String) -> Route {
        func rewrite(_ path: String) -> String? {
            if path == from { return to }
            if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
            return nil
        }
        switch self {
        case .file(let path): return rewrite(path).map(Route.file) ?? self
        case .folder(let path): return rewrite(path).map(Route.folder) ?? self
        default: return self
        }
    }

    /// 是否指向 `path`（或其下）
    func points(into path: String) -> Bool {
        switch self {
        case .file(let p), .folder(let p): p == path || p.hasPrefix(path + "/")
        default: false
        }
    }
}
