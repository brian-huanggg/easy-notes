import CryptoKit
import Foundation
import os

/// 同步引擎：只看 file id、path、內容 hash 與版本，合併交給各 DocumentKind。
///
/// 一輪同步 = 掃描本地 → 拉取遠端 → 上傳本地變更；上傳遇到版本衝突時再拉一次（最多 3 輪）。
/// 狀態存在 `.easynotes/sync.sqlite`，合併基準存在 `.easynotes/cache/base/<hash>`，
/// 兩者都可以刪掉：基準會從內容定址的 Storage 重新下載。
public actor SyncEngine {
    /// 刪除後可還原的天數；伺服器端的 pg_cron 同樣以 30 天清除
    public static let retentionDays = 30
    static let log = Logger(subsystem: "app.easynotes", category: "sync")

    public enum RestoreError: Error, LocalizedError {
        case changedOnServer
        public var errorDescription: String? { "這個檔案在其他裝置上有新的變更，請同步後再試" }
    }
    public struct Status: Sendable, Equatable {
        public var isSyncing = false
        /// 待上傳的檔案數
        public var pending = 0
        public var lastSynced: Date?
        public var lastError: String?
        /// 最近一輪產生的衝突副本
        public var conflicts: [String] = []

        public init() {}
    }

    /// 同步要動到本地檔案時通知 App（編輯器、索引、檔案樹）
    public struct Hooks: Sendable {
        /// 改寫、搬移或刪除 `path` 前呼叫：讓編輯器把未存的變更寫回磁碟
        public var willChange: @Sendable (_ path: String) async -> Void
        /// 改寫、搬移或刪除後呼叫。`oldPath` 不為 nil = 從那裡搬過來；`data` 為新內容（只搬移時為 nil）；
        /// 兩者都是 nil = 已刪除
        public var didChange: @Sendable (_ path: String, _ oldPath: String?, _ data: Data?) async -> Void
        public var statusChanged: @Sendable (Status) async -> Void

        public init(willChange: @escaping @Sendable (String) async -> Void = { _ in },
                    didChange: @escaping @Sendable (String, String?, Data?) async -> Void = { _, _, _ in },
                    statusChanged: @escaping @Sendable (Status) async -> Void = { _ in }) {
            self.willChange = willChange
            self.didChange = didChange
            self.statusChanged = statusChanged
        }
    }

    public let deviceID: String
    private let fs: VaultFS
    private let backend: any SyncBackend
    private let deviceName: String
    private let syncedMetaFolders: [String]
    private let state: SyncState
    private let hooks: Hooks
    private var status = Status()
    private var running = false
    private var rerun = false

    private var baseCache: URL { fs.root.appending(path: "\(VaultFS.metaFolder)/cache/base", directoryHint: .isDirectory) }

    /// - Parameters:
    ///   - userID: 換帳號時清空本地同步狀態（檔案留著，下一輪以 hash 對上遠端）
    ///   - deviceName: 衝突副本檔名用，例如「iPad」
    ///   - syncedMetaFolders: `.easynotes/` 下參與同步的子資料夾（`PluginRegistry.syncedMetaFolders`）
    public init(fs: VaultFS, backend: any SyncBackend, userID: String, deviceName: String,
                syncedMetaFolders: [String] = [], stateURL: URL? = nil, hooks: Hooks = Hooks()) throws {
        self.fs = fs
        self.backend = backend
        self.deviceName = deviceName
        self.syncedMetaFolders = syncedMetaFolders
        self.hooks = hooks
        state = try SyncState(url: stateURL ?? fs.root.appending(path: "\(VaultFS.metaFolder)/sync.sqlite"))
        if state[meta: "user"] != userID {
            try state.removeAll()
            state[meta: "user"] = userID
        }
        // 舊版的 id 存在 sync.sqlite：搬到 `.easynotes/device-id`，id 不變
        deviceID = try fs.deviceID(migrating: state[meta: "device"])
    }

    public var currentStatus: Status { status }

    /// 執行一輪同步。同步進行中再被呼叫時，結束後再跑一輪，不會重疊執行。
    public func sync() async {
        if running {
            rerun = true
            return
        }
        running = true
        repeat {
            rerun = false
            status.isSyncing = true
            status.conflicts = []
            await publish()
            do {
                for move in try scanLocal() { await hooks.didChange(move.to, move.from, nil) }
                for _ in 0..<3 {
                    try await pull()
                    if try await push() == 0 { break }
                }
                status.lastSynced = Date()
                status.lastError = nil
            } catch {
                status.lastError = "\(error)"
                Self.log.error("sync failed: \(error, privacy: .public)")
            }
            status.isSyncing = false
            await publish()
        } while rerun
        running = false
    }

    /// App 內改名或搬移（含資料夾）：直接更新路徑，保留 file id
    public func moved(from oldPath: String, to newPath: String) throws {
        for var r in state.records.values where r.path == oldPath || r.path.hasPrefix(oldPath + "/") {
            r.path = newPath + r.path.dropFirst(oldPath.count)
            try state.save(r)
        }
    }

    // MARK: 最近刪除

    /// 30 天內在任何裝置上刪除、本地也不存在的檔案，最新刪除的在前；伴隨檔不列出（隨主檔還原）
    public func recentlyDeleted() async throws -> [RemoteFile] {
        try await deletedLocally().filter { !fs.kinds.isCompanion($0.path) }
    }

    private func deletedLocally() async throws -> [RemoteFile] {
        let since = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        return try await backend.deletedFiles(since: since).filter { file in
            guard let r = state.records[file.id] else { return true }
            return r.localDeleted
        }
    }

    /// 以同一個 file id 還原到原路徑（被佔用時改用衝突副本的命名），回傳還原後的路徑。
    /// 同一路徑最近刪除的伴隨檔一起還原到主檔旁
    @discardableResult
    public func restore(_ file: RemoteFile) async throws -> String {
        let path = try await restoreFile(file, to: file.path)
        var latest: [String: RemoteFile] = [:]
        for c in try await deletedLocally() where fs.kinds.mainFile(ofCompanion: c.path) == file.path {
            if latest[c.path].map({ c.updatedAt > $0.updatedAt }) ?? true { latest[c.path] = c }
        }
        for c in latest.values.sorted(by: { $0.path < $1.path }) {
            guard let target = fs.kinds.companionPath(c.path, from: file.path, to: path) else { continue }
            _ = try await restoreFile(c, to: target)
        }
        return path
    }

    private func restoreFile(_ file: RemoteFile, to original: String) async throws -> String {
        let data = try await content(hash: file.hash)
        var path = original
        if FileManager.default.fileExists(atPath: fs.url(for: path).path(percentEncoded: false)) {
            path = conflictPath(for: path)
        }
        let request = CommitRequest(id: file.id, baseVersion: file.version, path: path, hash: file.hash,
                                    size: data.count, deleted: false, deviceID: deviceID)
        guard let version = try await backend.commit(request) else { throw RestoreError.changedOnServer }
        Self.log.info("restore \(path, privacy: .public) v\(version)")
        var r = SyncRecord(id: file.id, path: path, hash: file.hash, mtime: 0, size: data.count)
        try write(data, to: path, record: &r)
        r.baseVersion = version
        r.baseHash = file.hash
        r.basePath = path
        try cacheBase(data, hash: file.hash)
        try state.save(r)
        await publish()
        await hooks.didChange(path, nil, data)
        return path
    }

    private func publish() async {
        status.pending = state.records.values.filter(\.needsPush).count
        await hooks.statusChanged(status)
    }

    // MARK: 掃描本地

    /// 比對磁碟與同步狀態：只在 mtime 或大小改變時重算 hash。
    /// 外部工具改名會看到「刪除 + 新增」，兩者 hash 相同時推斷為改名並保留 file id；
    /// 主檔被推斷為改名時，留在原地的伴隨檔一起搬過去。回傳搬移的伴隨檔
    @discardableResult
    func scanLocal() throws -> [(from: String, to: String)] {
        let disk = try diskFiles()
        var unseen = Dictionary(state.records.values.filter { !$0.localDeleted }.map { ($0.path, $0.id) },
                                uniquingKeysWith: { a, _ in a })
        var added: [String] = []
        for (path, stat) in disk {
            guard let id = unseen.removeValue(forKey: path) else {
                added.append(path)
                continue
            }
            var r = state.records[id]!
            guard r.mtime != stat.mtime || r.size != stat.size else { continue }
            r.hash = try hash(of: path)
            r.mtime = stat.mtime
            r.size = stat.size
            try state.save(r)
        }
        // 消失的檔案與之前已刪除、尚未上傳的檔案，都可能是改名的來源
        var vanished = unseen.values.map { state.records[$0]! } + state.records.values.filter(\.localDeleted)
        var renamed: [(from: String, to: String)] = []
        for path in added.sorted() {
            let stat = disk[path]!
            let hash = try hash(of: path)
            if let i = vanished.firstIndex(where: { $0.hash == hash }) {
                var r = vanished.remove(at: i)
                renamed.append((r.path, path))
                r.path = path
                r.localDeleted = false
                r.mtime = stat.mtime
                r.size = stat.size
                try state.save(r)
            } else {
                try state.save(SyncRecord(id: UUID(), path: path, hash: hash, mtime: stat.mtime, size: stat.size))
            }
        }
        for var r in vanished where !r.localDeleted {
            if r.baseVersion == nil {
                try state.remove(r.id)
            } else {
                r.localDeleted = true
                try state.save(r)
            }
        }
        return try moveCompanions(renamed)
    }

    /// 外部工具只改了主檔的名字：把原地的伴隨檔搬到新名字旁，保留 file id
    private func moveCompanions(_ renamed: [(from: String, to: String)]) throws -> [(from: String, to: String)] {
        var moves: [(from: String, to: String)] = []
        for (old, new) in renamed where !fs.exists(old) {
            for move in fs.companionMoves(from: old, to: new) where !fs.exists(move.to) {
                try FileManager.default.moveItem(at: fs.url(for: move.from), to: fs.url(for: move.to))
                if var r = state.records.values.first(where: { $0.path == move.from && !$0.localDeleted }) {
                    r.path = move.to
                    try state.save(r)
                }
                Self.log.info("companion \(move.from, privacy: .public) → \(move.to, privacy: .public)")
                moves.append(move)
            }
        }
        return moves
    }

    /// 參與同步的檔案：Vault 內所有一般檔案，略過隱藏檔與 `.easynotes/`（索引、快取、同步狀態），
    /// 但包含外掛註冊的 `.easynotes/<folder>/`
    private func diskFiles() throws -> [String: (mtime: Double, size: Int)] {
        let roots = [fs.root] + syncedMetaFolders.map {
            fs.root.appending(path: "\(VaultFS.metaFolder)/\($0)", directoryHint: .isDirectory)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var result: [String: (mtime: Double, size: Int)] = [:]
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in walker {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                result[fs.path(for: url)] = (values.contentModificationDate?.timeIntervalSince1970 ?? 0, values.fileSize ?? 0)
            }
        }
        return result
    }

    // MARK: 拉取

    private func pull() async throws {
        let cursor = state[meta: "cursor"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        for row in try await backend.changes(since: cursor) {
            try await apply(row)
            if row.updatedAt > cursor ?? .distantPast {
                state[meta: "cursor"] = String(row.updatedAt.timeIntervalSince1970)
            }
        }
    }

    private func apply(_ row: RemoteFile) async throws {
        guard var r = state.records[row.id] else {
            if !row.deleted { try await applyNew(row) }
            return
        }
        if let base = r.baseVersion, row.version <= base { return } // 自己的提交或已套用過
        if !r.localDeleted {
            await hooks.willChange(r.path)
            try refreshHash(&r)
        }

        if row.deleted {
            if r.localDeleted {
                try state.remove(r.id)
            } else if r.needsPush {
                // 修改勝過刪除：保留本地，下次上傳時復活
                r.baseVersion = row.version
                r.basePath = row.path
                try state.save(r)
            } else {
                try FileManager.default.removeItem(at: fs.url(for: r.path))
                try state.remove(r.id)
                await hooks.didChange(r.path, nil, nil)
            }
            return
        }

        if r.localDeleted {
            guard row.hash != r.baseHash || row.path != r.basePath else {
                r.baseVersion = row.version // 遠端沒有實質變更，刪除照常上傳
                try state.save(r)
                return
            }
            // 修改勝過刪除：還原遠端版本
            let data = try await content(hash: row.hash)
            let path = try await makeRoom(at: row.path, for: r.id)
            try write(data, to: path, record: &r)
            r.localDeleted = false
            setBase(&r, row, data: data)
            try state.save(r)
            await hooks.didChange(path, nil, data)
            return
        }

        let oldPath = r.path
        var newData: Data?
        if row.hash != r.baseHash {
            let remote = try await content(hash: row.hash)
            if r.hash == r.baseHash {
                newData = remote
            } else {
                let local = try fs.read(r.path)
                var base: Data?
                if let baseHash = r.baseHash { base = try await content(hash: baseHash) }
                if let merged = kind(for: r.path).merge(base: base, local: local, remote: remote) {
                    newData = merged
                } else {
                    try await createConflictCopy(of: local, for: r.path)
                    newData = remote
                }
            }
            try cacheBase(remote, hash: row.hash)
        }
        // 本地沒改名才跟著遠端改名；兩邊都改名時保留本地的，下次上傳覆蓋遠端
        if row.path != r.basePath, r.path == r.basePath, row.path != r.path {
            let target = try await makeRoom(at: row.path, for: r.id)
            try FileManager.default.createDirectory(at: fs.url(for: target).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fs.url(for: r.path), to: fs.url(for: target))
            r.path = target
        }
        if let newData { try write(newData, to: r.path, record: &r) }
        setBase(&r, row, data: nil)
        try state.save(r)
        if newData != nil || r.path != oldPath {
            await hooks.didChange(r.path, r.path != oldPath ? oldPath : nil, newData)
        }
    }

    /// 本地沒有這個 id 的遠端檔案
    private func applyNew(_ row: RemoteFile) async throws {
        let remote = try await content(hash: row.hash)
        var r = SyncRecord(id: row.id, path: row.path, hash: row.hash, mtime: 0, size: row.size)
        if var occupant = state.record(at: row.path) {
            await hooks.willChange(occupant.path)
            try refreshHash(&occupant)
            if occupant.baseVersion == nil, occupant.hash == row.hash {
                // 兩台裝置各自建立了相同內容（例如範例檔）：採用遠端的 id
                try state.remove(occupant.id)
                r.mtime = occupant.mtime
                setBase(&r, row, data: remote)
                try state.save(r)
                return
            }
            let local = try fs.read(occupant.path)
            if occupant.baseVersion == nil, let merged = kind(for: row.path).merge(base: nil, local: local, remote: remote) {
                try state.remove(occupant.id)
                try write(merged, to: row.path, record: &r)
                setBase(&r, row, data: remote)
                try state.save(r)
                await hooks.didChange(row.path, nil, merged)
                return
            }
            // 路徑被另一個檔案佔用：本地那份讓位成衝突副本
            _ = try await makeRoom(at: row.path, for: row.id)
        }
        try write(remote, to: row.path, record: &r)
        setBase(&r, row, data: remote)
        try state.save(r)
        await hooks.didChange(row.path, nil, remote)
    }

    // MARK: 上傳

    /// 回傳被伺服器拒絕（版本不符）的數量
    private func push() async throws -> Int {
        var rejected = 0
        for var r in state.records.values.sorted(by: { $0.path < $1.path }) where r.needsPush {
            if r.localDeleted {
                guard let baseVersion = r.baseVersion, let baseHash = r.baseHash else {
                    try state.remove(r.id)
                    continue
                }
                let request = CommitRequest(id: r.id, baseVersion: baseVersion, path: r.basePath ?? r.path,
                                            hash: baseHash, size: r.size, deleted: true, deviceID: deviceID)
                if let version = try await backend.commit(request) {
                    Self.log.info("commit delete \(request.path, privacy: .public) v\(version)")
                    try state.remove(r.id)
                } else {
                    rejected += 1
                }
                continue
            }
            // 掃描之後可能又被修改：上傳磁碟上的最新內容
            let data = try fs.read(r.path)
            r.hash = Self.sha256(data)
            r.size = data.count
            try await backend.upload(data, hash: r.hash)
            let request = CommitRequest(id: r.id, baseVersion: r.baseVersion, path: r.path, hash: r.hash,
                                        size: data.count, deleted: false, deviceID: deviceID)
            if let version = try await backend.commit(request) {
                Self.log.info("commit \(r.path, privacy: .public) v\(version) \(data.count) bytes")
                try cacheBase(data, hash: r.hash)
                let oldBase = r.baseHash
                r.baseVersion = version
                r.baseHash = r.hash
                r.basePath = r.path
                try state.save(r)
                dropBase(oldBase)
            } else {
                try state.save(r)
                rejected += 1
            }
        }
        return rejected
    }

    // MARK: 工具

    private func kind(for path: String) -> any DocumentKind.Type {
        fs.kinds.kind(for: path) ?? OpaqueKind.self
    }

    private func refreshHash(_ r: inout SyncRecord) throws {
        guard let stat = try fs.fileStat(r.path) else { return }
        guard stat.mtime != r.mtime || stat.size != r.size else { return }
        r.hash = try hash(of: r.path)
        r.mtime = stat.mtime
        r.size = stat.size
    }

    private func write(_ data: Data, to path: String, record r: inout SyncRecord) throws {
        try fs.write(data, to: path)
        r.path = path
        r.hash = Self.sha256(data)
        let stat = try fs.fileStat(path)
        r.mtime = stat?.mtime ?? 0
        r.size = stat?.size ?? data.count
    }

    private func setBase(_ r: inout SyncRecord, _ row: RemoteFile, data: Data?) {
        let oldBase = r.baseHash
        r.baseVersion = row.version
        r.baseHash = row.hash
        r.basePath = row.path
        if let data { try? cacheBase(data, hash: row.hash) }
        if oldBase != row.hash { dropBase(oldBase) }
    }

    /// 合併基準：先找本地快取，沒有就從 Storage 下載（內容定址，舊版本永遠在）
    private func content(hash: String) async throws -> Data {
        let cached = baseCache.appending(path: hash)
        if let data = try? Data(contentsOf: cached) { return data }
        if let r = state.records.values.first(where: { $0.hash == hash && !$0.localDeleted }),
           let data = try? fs.read(r.path), Self.sha256(data) == hash {
            return data
        }
        return try await backend.download(hash: hash)
    }

    private func cacheBase(_ data: Data, hash: String) throws {
        try FileManager.default.createDirectory(at: baseCache, withIntermediateDirectories: true)
        let url = baseCache.appending(path: hash)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try data.write(to: url, options: .atomic)
        }
    }

    private func dropBase(_ hash: String?) {
        guard let hash, !state.records.values.contains(where: { $0.baseHash == hash }) else { return }
        try? FileManager.default.removeItem(at: baseCache.appending(path: hash))
    }

    /// `path` 被另一個本地檔案佔用時，把那個檔案改名成衝突副本，回傳可用的 `path`
    private func makeRoom(at path: String, for id: UUID) async throws -> String {
        guard var occupant = state.record(at: path), occupant.id != id else { return path }
        let copy = conflictPath(for: path)
        await hooks.willChange(path)
        try FileManager.default.moveItem(at: fs.url(for: path), to: fs.url(for: copy))
        occupant.path = copy
        try state.save(occupant)
        status.conflicts.append(copy)
        await hooks.didChange(copy, path, nil)
        return path
    }

    /// 衝突副本是新檔案，下一輪掃描會把它當成新增並上傳
    private func createConflictCopy(of data: Data, for path: String) async throws {
        let copy = conflictPath(for: path)
        try fs.write(data, to: copy)
        status.conflicts.append(copy)
        await hooks.didChange(copy, nil, data)
    }

    /// `筆記.md` → `筆記 (衝突 iPad 2026-10-01).md`，已存在時加上編號
    func conflictPath(for path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var stem = fs.kinds.displayName(name)
        if stem == name { stem = (name as NSString).deletingPathExtension } // 未註冊的類型，例如 .png
        let ext = String(name.dropFirst(stem.count))
        let date = Date().formatted(.iso8601.year().month().day())
        var n = 1
        while true {
            let suffix = n == 1 ? "" : " \(n)"
            let candidate = "\(stem) (衝突 \(deviceName) \(date)\(suffix))\(ext)"
            let full = dir.isEmpty ? candidate : "\(dir)/\(candidate)"
            if !FileManager.default.fileExists(atPath: fs.url(for: full).path(percentEncoded: false)) { return full }
            n += 1
        }
    }

    private func hash(of path: String) throws -> String {
        Self.sha256(try fs.read(path))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 未註冊的檔案類型（圖片、PDF…）：內容不同就產生衝突副本
private enum OpaqueKind: DocumentKind {
    static let id = "opaque"
    static let fileExtensions: [String] = []
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
}
