import Foundation

/// Vault 中的一個節點（資料夾或檔案）。以相對路徑作為身分，跨裝置同步時也用它。
public struct VaultNode: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isFolder: Bool
    public var children: [VaultNode]?

    public var displayName: String {
        isFolder ? name : (name as NSString).deletingPathExtension
    }
}

/// 檔案系統操作。檔案即真相：這裡沒有任何資料庫，索引都能由檔案重建。
public struct VaultFS: Sendable {
    public let root: URL
    /// App 設定與快取（類似 .obsidian/），不顯示在檔案樹中
    public static let metaFolder = ".easynotes"

    public init(root: URL) {
        self.root = root
    }

    public func url(for path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    public func path(for url: URL) -> String {
        let base = root.standardizedFileURL.path(percentEncoded: false)
        let full = url.standardizedFileURL.path(percentEncoded: false)
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: 掃描

    public func scan() throws -> [VaultNode] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try children(of: root)
    }

    private func children(of dir: URL) throws -> [VaultNode] {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try items.compactMap { url -> VaultNode? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                return VaultNode(path: path(for: url), name: url.lastPathComponent, isFolder: true,
                                 children: try children(of: url))
            }
            guard DocumentKinds.kind(for: url) != nil else { return nil }
            return VaultNode(path: path(for: url), name: url.lastPathComponent, isFolder: false, children: nil)
        }
        .sorted { lhs, rhs in
            lhs.isFolder != rhs.isFolder
                ? lhs.isFolder
                : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func allFiles() throws -> [VaultNode] {
        func flatten(_ nodes: [VaultNode]) -> [VaultNode] {
            nodes.flatMap { $0.isFolder ? flatten($0.children ?? []) : [$0] }
        }
        return flatten(try scan())
    }

    public struct FileStat: Sendable {
        public let path: String
        public let mtime: Double
        public let size: Int
    }

    public func fileStats() throws -> [FileStat] {
        try allFiles().compactMap { try fileStat($0.path) }
    }

    public func fileStat(_ path: String) throws -> FileStat? {
        let values = try? url(for: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let values else { return nil }
        return FileStat(path: path, mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        size: values.fileSize ?? 0)
    }

    // MARK: 讀寫

    public func read(_ path: String) throws -> Data {
        try Data(contentsOf: url(for: path))
    }

    /// Atomic write：先寫暫存檔再替換，當機或斷電不會留下半個檔案
    public func write(_ data: Data, to path: String) throws {
        let target = url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    /// 在資料夾中建立不重名的新檔案，回傳相對路徑
    public func create(kind: any DocumentKind.Type, title: String, in folder: String = "") throws -> String {
        let ext = kind.fileExtensions[0]
        var name = "\(title).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: url(for: join(folder, name)).path(percentEncoded: false)) {
            name = "\(title) \(n).\(ext)"
            n += 1
        }
        let path = join(folder, name)
        try write(kind.template(title: title), to: path)
        return path
    }

    public func createFolder(named name: String, in folder: String = "") throws -> String {
        let path = join(folder, name)
        try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        return path
    }

    public func rename(_ path: String, to newName: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let newPath = join(parent, newName)
        try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        return newPath
    }

    public func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: url(for: path), resultingItemURL: nil)
    }

    private func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    // MARK: 連結與搜尋（Phase 1 會換成 SQLite FTS5 索引）

    /// 依 [[名稱]] 找檔案：比對不含副檔名的檔名，不分大小寫
    public func resolveLink(_ target: String) throws -> String? {
        let wanted = target.lowercased()
        return try allFiles().first { $0.displayName.lowercased() == wanted }?.path
    }

    public func search(_ query: String) throws -> [VaultNode] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return try allFiles().filter { node in
            if node.displayName.localizedCaseInsensitiveContains(q) { return true }
            guard let kind = DocumentKinds.kind(for: url(for: node.path)),
                  let data = try? read(node.path) else { return false }
            return kind.index(data, fileName: node.name).plainText.localizedCaseInsensitiveContains(q)
        }
    }
}
