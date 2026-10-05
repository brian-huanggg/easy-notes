import Foundation

/// The shell's current location: sidebar selection, content area and back / forward history all use it
enum Route: Hashable, Codable {
    case all
    case recents
    case pinned
    /// A folder inside the vault (Spaces = first-level folders)
    case folder(String)
    case tag(String)
    case file(String)
    /// A sidebar item registered by a plugin with `addPanel`
    case panel(String)

    var filePath: String? {
        if case .file(let path) = self { path } else { nil }
    }

    /// After renaming or moving `from`, a location pointing at it (or below it) becomes `to`
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

    /// Whether this points at `path` (or below it)
    func points(into path: String) -> Bool {
        switch self {
        case .file(let p), .folder(let p): p == path || p.hasPrefix(path + "/")
        default: false
        }
    }
}
