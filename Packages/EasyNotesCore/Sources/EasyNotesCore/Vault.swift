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

    /// Vault 內的相對路徑是否安全：非空、不是絕對路徑、沒有 `.` / `..` 段、沒有 NUL 與反斜線。
    /// 來自遠端（同步）與 Bridge 的路徑在寫入或讀取前都要先通過這個檢查，避免離開 Vault。
    public static func isSafe(path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." || $0 == "." || $0.isEmpty }
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

    /// 檔案樹；伴隨檔（`DocumentKind.companionOf`）預設不列出
    public func scan(includingCompanions: Bool = false) throws -> [VaultNode] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try children(of: root, includingCompanions: includingCompanions)
    }

    private func children(of dir: URL, includingCompanions: Bool) throws -> [VaultNode] {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try items.compactMap { url -> VaultNode? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                return VaultNode(path: path(for: url), name: url.lastPathComponent, isFolder: true,
                                 children: try children(of: url, includingCompanions: includingCompanions))
            }
            guard kinds.kind(for: url) != nil else { return nil }
            if !includingCompanions, kinds.isCompanion(url.lastPathComponent) { return nil }
            return VaultNode(path: path(for: url), name: url.lastPathComponent, isFolder: false, children: nil)
        }
        .sorted { lhs, rhs in
            lhs.isFolder != rhs.isFolder
                ? lhs.isFolder
                : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func allFiles(includingCompanions: Bool = false) throws -> [VaultNode] {
        func flatten(_ nodes: [VaultNode]) -> [VaultNode] {
            nodes.flatMap { $0.isFolder ? flatten($0.children ?? []) : [$0] }
        }
        return flatten(try scan(includingCompanions: includingCompanions))
    }

    public struct FileStat: Sendable {
        public let path: String
        public let mtime: Double
        public let size: Int
    }

    public func fileStats() throws -> [FileStat] {
        // 伴隨檔照常索引（外部修改、同步拉下來的旁檔才能通知編輯器）
        try allFiles(includingCompanions: true).compactMap { try fileStat($0.path) }
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

    /// App 存檔用：磁碟上的內容已不是 `expected`（外部工具剛寫入、App 還沒套用）時不直接覆寫，
    /// 以 `expected` 為 base 交給 `DocumentKind.merge`；無法合併時磁碟上的版本留在原處，`data` 另存成衝突副本。
    /// `expected` 為 nil（不知道上次的內容）時直接寫入。回傳 `path` 上實際寫入的內容與衝突副本的路徑
    public func write(_ data: Data, to path: String, expecting expected: Data?,
                      deviceName: String) throws -> (data: Data, conflictCopy: String?) {
        guard let expected, let current = try? read(path), current != expected, current != data else {
            try write(data, to: path)
            return (data, nil)
        }
        if let merged = kinds.kind(for: path)?.merge(base: expected, local: data, remote: current) {
            if merged != current { try write(merged, to: path) }
            return (merged, nil)
        }
        let copy = conflictPath(for: path, deviceName: deviceName)
        try write(data, to: copy)
        return (current, copy)
    }

    /// `筆記.md` → `筆記 (衝突 iPad 2026-10-01).md`，已存在時加上編號
    public func conflictPath(for path: String, deviceName: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var stem = kinds.displayName(name)
        if stem == name { stem = (name as NSString).deletingPathExtension } // 未註冊的類型，例如 .png
        let ext = String(name.dropFirst(stem.count))
        let date = Date().formatted(.iso8601.year().month().day())
        var n = 1
        while true {
            let suffix = n == 1 ? "" : " \(n)"
            let candidate = "\(stem) (\(SyncEngine.conflictMarker) \(deviceName) \(date)\(suffix))\(ext)"
            let full = dir.isEmpty ? candidate : "\(dir)/\(candidate)"
            if !exists(full) { return full }
            n += 1
        }
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

    /// 改名；檔案的伴隨檔一起改名（見 `companionMoves`）
    public func rename(_ path: String, to newName: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let newPath = join(parent, newName)
        let companions = companionMoves(from: path, to: newPath)
        try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        for move in companions where !exists(move.to) {
            try FileManager.default.moveItem(at: url(for: move.from), to: url(for: move.to))
        }
        return newPath
    }

    /// 搬到另一個資料夾（`""` = 根目錄），名稱不變；伴隨檔一起搬移。
    /// 目的地有同名項目、或把資料夾搬進自己時丟出錯誤
    public func move(_ path: String, toFolder folder: String) throws -> String {
        let newPath = join(folder, (path as NSString).lastPathComponent)
        guard newPath != path else { return path }
        guard folder != path, !folder.hasPrefix(path + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        guard !exists(newPath) else { throw CocoaError(.fileWriteFileExists) }
        let companions = companionMoves(from: path, to: newPath)
        try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        for move in companions where !exists(move.to) {
            try FileManager.default.moveItem(at: url(for: move.from), to: url(for: move.to))
        }
        return newPath
    }

    /// 刪除（移到垃圾桶）；檔案的伴隨檔一起刪除
    public func trash(_ path: String) throws {
        let companions = companions(of: path)
        try FileManager.default.trashItem(at: url(for: path), resultingItemURL: nil)
        for companion in companions { try FileManager.default.trashItem(at: url(for: companion), resultingItemURL: nil) }
    }

    /// 與 `path` 同資料夾、主檔是 `path` 的伴隨檔
    public func companions(of path: String) -> [String] {
        let parent = (path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? root : url(for: parent)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        return names.map { join(parent, $0) }.filter { kinds.mainFile(ofCompanion: $0) == path }.sorted()
    }

    /// 主檔從 `path` 搬到 `newPath` 時，各伴隨檔的搬移（資料夾不處理：伴隨檔本來就在裡面）
    public func companionMoves(from path: String, to newPath: String) -> [(from: String, to: String)] {
        companions(of: path).compactMap { c in kinds.companionPath(c, from: path, to: newPath).map { (c, $0) } }
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path(percentEncoded: false))
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
