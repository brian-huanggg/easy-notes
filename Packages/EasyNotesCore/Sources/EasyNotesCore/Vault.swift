import Foundation

/// Vault 中的一個節點（資料夾或檔案）。UI 以相對路徑識別；跨裝置同步另有穩定的 file id（見 SyncEngine）。
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
    public let kinds: KindRegistry
    /// App 設定與快取（類似 .obsidian/），不顯示在檔案樹中
    public static let metaFolder = ".easynotes"

    public init(root: URL, kinds: KindRegistry) {
        self.root = root
        self.kinds = kinds
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

    // MARK: 裝置

    /// 這台裝置的 id，存在 `.easynotes/device-id`（不同步）；第一次呼叫時建立。
    /// `migrating`：沒有 device-id 時改用這個值（舊版存在 `sync.sqlite` 的 id），讓 id 不變
    public func deviceID(migrating existing: String? = nil) throws -> String {
        let url = url(for: "\(Self.metaFolder)/device-id")
        if let data = try? Data(contentsOf: url) {
            let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        let id = existing ?? UUID().uuidString
        try write(Data((id + "\n").utf8), to: "\(Self.metaFolder)/device-id")
        return id
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
            guard kinds.kind(for: url) != nil else { return nil }
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

    /// 把 Vault 外的檔案複製進 `folder`，同名時加上編號；回傳相對路徑
    public func importFile(from source: URL, in folder: String = "") throws -> String {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        func name(_ n: Int) -> String {
            let stem = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var n = 1
        while FileManager.default.fileExists(atPath: url(for: join(folder, name(n))).path(percentEncoded: false)) { n += 1 }
        let path = join(folder, name(n))
        let target = url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
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
            guard let kind = kinds.kind(for: node.path),
                  let data = try? read(node.path) else { return false }
            return kind.index(data, fileName: node.name).plainText.localizedCaseInsensitiveContains(q)
        }
    }
}
