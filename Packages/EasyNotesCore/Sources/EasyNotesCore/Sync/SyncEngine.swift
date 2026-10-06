import CryptoKit
import Foundation
import os

/// The sync engine: sees only file id, path, content hash and version, and delegates merging to each DocumentKind.
///
/// One sync round = scan local → pull remote → upload local changes; on a version conflict during upload it pulls again (at most 3 rounds).
/// State lives in `.easynotes/sync.sqlite` and merge bases in `.easynotes/cache/base/<hash>`,
/// both of which can be deleted: bases are downloaded again from content-addressed Storage.
public actor SyncEngine {
    /// Days a deletion can be restored; the server-side pg_cron purges at 30 days as well
    public static let retentionDays = 30
    /// The marker in conflict-copy file names: synced to every device and recognized by the app, so it does not change with the UI language
    public static let conflictMarker = "衝突" // l10n:fixed
    /// Whether `name` is a conflict copy of `stem`
    public static func isConflictCopy(_ name: String, of stem: String) -> Bool {
        name.hasPrefix("\(stem) (\(conflictMarker)")
    }
    static let log = Logger(subsystem: "app.easynotes", category: "sync")

    public enum RestoreError: Error, LocalizedError {
        case changedOnServer
        case unsafePath
        public var errorDescription: String? {
            switch self {
            case .changedOnServer: L("這個檔案在其他裝置上有新的變更，請同步後再試")
            case .unsafePath: L("遠端的檔案路徑不安全，已拒絕還原")
            }
        }
    }
    /// Downloaded content does not match its SHA-256: cloud content was tampered with or corrupted in transit; it is neither applied nor cached
    public struct HashMismatchError: Error, LocalizedError {
        public var errorDescription: String? { L("下載的內容與雜湊不符，已拒絕套用") }
    }
    public struct Status: Sendable, Equatable {
        public var isSyncing = false
        /// Number of files pending upload
        public var pending = 0
        public var lastSynced: Date?
        public var lastError: String?
        /// Conflict copies produced in the latest round
        public var conflicts: [String] = []

        public init() {}
    }

    /// Notifies the app (editors, index, file tree) when sync is about to touch local files
    public struct Hooks: Sendable {
        /// Called before rewriting, moving or deleting `path`: lets the editor write unsaved changes to disk
        public var willChange: @Sendable (_ path: String) async -> Void
        /// Called after rewriting, moving or deleting. `oldPath` not nil = moved from there; `data` is the new content (nil for a pure move);
        /// both nil = deleted
        public var didChange: @Sendable (_ path: String, _ oldPath: String?, _ data: Data?) async -> Void
        public var statusChanged: @Sendable (Status) async -> Void
        /// Files were permanently deleted by another device or from "Recently Deleted" (called after `didChange`, so the app's view of what is
        /// alive is current): the app drops what it derived from them, such as preview thumbnails
        public var didPurge: @Sendable () async -> Void

        public init(willChange: @escaping @Sendable (String) async -> Void = { _ in },
                    didChange: @escaping @Sendable (String, String?, Data?) async -> Void = { _, _, _ in },
                    statusChanged: @escaping @Sendable (Status) async -> Void = { _ in },
                    didPurge: @escaping @Sendable () async -> Void = {}) {
            self.willChange = willChange
            self.didChange = didChange
            self.statusChanged = statusChanged
            self.didPurge = didPurge
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
    ///   - userID: when the account changes, clears local sync state (files stay and match the remote by hash in the next round)
    ///   - deviceName: used in conflict-copy file names, for example "iPad"
    ///   - syncedMetaFolders: subfolders under `.easynotes/` that take part in sync (`PluginRegistry.syncedMetaFolders`)
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
        // Older versions kept the id in sync.sqlite: move it to `.easynotes/device-id`, the id unchanged
        deviceID = try fs.deviceID(migrating: state[meta: "device"])
    }

    public var currentStatus: Status { status }

    /// Runs one sync round. When called while a sync is in progress, another round runs after it finishes; rounds never overlap.
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

    /// In-app rename or move (including folders): updates the path directly and keeps the file id
    public func moved(from oldPath: String, to newPath: String) throws {
        for var r in state.records.values where r.path == oldPath || r.path.hasPrefix(oldPath + "/") {
            r.path = newPath + r.path.dropFirst(oldPath.count)
            try state.save(r)
        }
    }

    // MARK: Recently deleted

    /// Files deleted within 30 days on any device and also missing locally, most recently deleted first; companions are not listed (restored with the main file)
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

    /// Restores to the original path with the same file id (using conflict-copy naming when occupied) and returns the restored path.
    /// A companion recently deleted at the same path is restored next to the main file
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
        guard VaultFS.isSafe(path: file.path), VaultFS.isSafe(path: original) else { throw RestoreError.unsafePath }
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

    // MARK: Permanent delete

    /// "Delete Immediately": marks the file at `path` (a folder = every file under it) and their companions, so the next upload purges
    /// them on the server instead of soft-deleting them. **Call this before removing the files from disk**: a scan that sees a vanished
    /// file without the mark would soft-delete it. Companions are found through the record table, so a PDF's sidecar or a sheet's
    /// `.meta.json` goes with its main file without this layer knowing any type. Returns the paths marked.
    @discardableResult
    public func requestPurge(_ path: String) async throws -> [String] {
        let live = state.records.values.filter { !$0.localDeleted }
        let mains = Set(live.filter { $0.path == path || $0.path.hasPrefix(path + "/") }.map(\.path))
        let targets = live.filter { r in
            mains.contains(r.path) || fs.kinds.mainFile(ofCompanion: r.path).map { mains.contains($0) } == true
        }
        for var r in targets {
            r.purgeRequested = true
            try state.save(r)
        }
        await publish()
        return targets.map(\.path).sorted()
    }

    /// Permanently deletes one entry of "Recently Deleted" together with the companion deleted next to it (the same companion `restore` would bring back).
    /// Needs the network: unlike "Delete Immediately" there is no file left to carry a pending mark.
    public func purge(_ file: RemoteFile) async throws {
        var files = [file]
        var latest: [String: RemoteFile] = [:]
        for c in try await deletedLocally() where fs.kinds.mainFile(ofCompanion: c.path) == file.path {
            if latest[c.path].map({ c.updatedAt > $0.updatedAt }) ?? true { latest[c.path] = c }
        }
        files += latest.values
        try await purgeRemote(files)
    }

    /// "Empty Trash": permanently deletes everything in "Recently Deleted", including the companions that the list hides.
    /// Returns the number of files deleted.
    @discardableResult
    public func purgeAllDeleted() async throws -> Int {
        var total = 0
        var seen = Set<UUID>()
        // The backend lists in pages; deleted rows leave the list, so ask again until nothing new shows up
        while true {
            let batch = try await deletedLocally().filter { seen.insert($0.id).inserted }
            guard !batch.isEmpty else { return total }
            try await purgeRemote(batch)
            total += batch.count
        }
    }

    private func purgeRemote(_ files: [RemoteFile]) async throws {
        try await backend.purge(ids: files.map(\.id), deviceID: deviceID)
        Self.log.info("purge \(files.count) files")
        for f in files {
            if let r = state.records[f.id] { try state.remove(r.id) }
            dropBase(f.hash)
        }
        await hooks.didPurge()
    }

    private func publish() async {
        status.pending = state.records.values.filter(\.needsPush).count
        await hooks.statusChanged(status)
    }

    // MARK: Scan local

    /// Compares disk with sync state: the hash is recomputed only when mtime or size changes.
    /// An external tool rename shows as "delete + add"; when both have the same hash it infers a rename and keeps the file id;
    /// when a main file is inferred to be renamed, a companion left behind moves with it. Returns the companions moved
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
        // Both vanished files and files deleted earlier but not yet uploaded can be the source of a rename
        // A file marked for permanent delete never counts as renamed: the user chose to destroy it, not move it
        var vanished = (unseen.values.map { state.records[$0]! } + state.records.values.filter(\.localDeleted))
            .filter { !$0.purgeRequested }
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

    /// An external tool changed only the main file's name: moves the companion left behind next to the new name, keeping the file id
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

    /// Files that take part in sync: all ordinary files in the vault, skipping hidden files and `.easynotes/` (index, cache, sync state),
    /// but including the `.easynotes/<folder>/` that plugins registered
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

    // MARK: Pull

    private func pull() async throws {
        let cursor = state[meta: "cursor"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        for row in try await backend.changes(since: cursor) {
            if VaultFS.isSafe(path: row.path) {
                try await apply(row)
            } else {
                Self.log.error("skip remote file with unsafe path \(row.id.uuidString, privacy: .public)")
            }
            if row.updatedAt > cursor ?? .distantPast {
                state[meta: "cursor"] = String(row.updatedAt.timeIntervalSince1970)
            }
        }
    }

    private func apply(_ row: RemoteFile) async throws {
        guard let known = state.records[row.id] else {
            if !row.deleted { try await applyNew(row) }
            return
        }
        if row.purged {
            try await applyPurge(row, known: known)
            return
        }
        // This device is deleting the file for good: remote edits or renames must not bring it back
        if known.purgeRequested { return }
        if let base = known.baseVersion, row.version <= base { return } // Our own commit, or already applied
        // Download first (network), then have the editor write back: text typed during the download is included in the merge and not overwritten by remote content
        var remoteData: Data?
        var baseData: Data?
        if !known.localDeleted, !row.deleted, row.hash != known.baseHash {
            remoteData = try await content(hash: row.hash)
            if let baseHash = known.baseHash { baseData = try await content(hash: baseHash) }
        }
        if !known.localDeleted { await hooks.willChange(known.path) }
        // The app may rename or move during the wait (`moved`): the latest record wins
        guard var r = state.records[row.id] else { return }
        if !r.localDeleted { try refreshHash(&r) }

        if row.deleted {
            if r.localDeleted {
                try state.remove(r.id)
                dropBase(r.baseHash)
            } else if r.needsPush {
                // Modify beats delete: keep local and revive it on the next upload
                r.baseVersion = row.version
                r.basePath = row.path
                try state.save(r)
            } else {
                try FileManager.default.removeItem(at: fs.url(for: r.path))
                try state.remove(r.id)
                dropBase(r.baseHash) // A restore downloads the content again; the merge base of a deleted file is dead weight (and stays readable on disk)
                await hooks.didChange(r.path, nil, nil)
            }
            return
        }

        if r.localDeleted {
            guard row.hash != r.baseHash || row.path != r.basePath else {
                r.baseVersion = row.version // The remote has no substantive change, so the delete uploads as usual
                try state.save(r)
                return
            }
            // Modify beats delete: restore the remote version
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
        if row.hash != r.baseHash {
            if remoteData == nil { remoteData = try await content(hash: row.hash) }
            if baseData == nil, let baseHash = r.baseHash { baseData = try await content(hash: baseHash) }
        }
        // Follow the remote rename only if local did not rename; when both renamed, keep the local one and overwrite the remote on the next upload
        if row.path != r.basePath, r.path == r.basePath, row.path != r.path {
            let target = try await makeRoom(at: row.path, for: r.id)
            try FileManager.default.createDirectory(at: fs.url(for: target).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fs.url(for: r.path), to: fs.url(for: target))
            r.path = target
        }
        // No await between reading local and writing back: the editor cannot write in between and be overwritten
        var newData: Data?
        var conflict: (path: String, data: Data)?
        if row.hash != r.baseHash, let remote = remoteData {
            let local = try fs.read(r.path)
            r.hash = Self.sha256(local)
            if r.hash == r.baseHash {
                newData = remote
            } else if let merged = kind(for: r.path).merge(base: baseData, local: local, remote: remote) {
                newData = merged
            } else {
                let copy = try writeConflictCopy(of: local, for: r.path)
                conflict = (path: copy, data: local)
                newData = remote
            }
            try cacheBase(remote, hash: row.hash)
        }
        if let newData { try write(newData, to: r.path, record: &r) }
        setBase(&r, row, data: nil)
        try state.save(r)
        if let conflict { await hooks.didChange(conflict.path, nil, conflict.data) }
        if newData != nil || r.path != oldPath {
            await hooks.didChange(r.path, r.path != oldPath ? oldPath : nil, newData)
        }
    }

    /// Another device (or this one, earlier) permanently deleted the file: drops it locally. A file with unsynced local edits is the one exception
    /// (the same "modify beats delete" rule as soft delete): it is kept and re-registered as a new, never uploaded file, because the
    /// tombstone can never be committed over.
    private func applyPurge(_ row: RemoteFile, known: SyncRecord) async throws {
        if known.localDeleted || known.purgeRequested {
            try state.remove(known.id)
            dropBase(known.baseHash)
            return
        }
        await hooks.willChange(known.path)
        guard var r = state.records[row.id] else { return }
        try refreshHash(&r)
        if r.hash != r.baseHash {
            Self.log.info("purged on another device but edited here: keeping \(r.path, privacy: .public) as a new file")
            let oldBase = r.baseHash
            try state.remove(r.id)
            r.id = UUID()
            r.baseVersion = nil
            r.baseHash = nil
            r.basePath = nil
            try state.save(r)
            dropBase(oldBase)
            return
        }
        try? FileManager.default.removeItem(at: fs.url(for: r.path))
        try state.remove(r.id)
        dropBase(r.baseHash)
        await hooks.didChange(r.path, nil, nil)
        await hooks.didPurge()
    }

    /// A remote file whose id local does not have
    private func applyNew(_ row: RemoteFile) async throws {
        let remote = try await content(hash: row.hash)
        // A local file created after the scan (for example a just-added note): first register it as a local new file, then adopt, merge or yield by content, never overwriting directly
        if state.record(at: row.path) == nil, let stat = try fs.fileStat(row.path) {
            try state.save(SyncRecord(id: UUID(), path: row.path, hash: try hash(of: row.path),
                                      mtime: stat.mtime, size: stat.size))
        }
        var r = SyncRecord(id: row.id, path: row.path, hash: row.hash, mtime: 0, size: row.size)
        if var occupant = state.record(at: row.path) {
            await hooks.willChange(occupant.path)
            try refreshHash(&occupant)
            if occupant.baseVersion == nil, occupant.hash == row.hash {
                // Two devices each created identical content (for example the sample files): adopt the remote's id
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
            // The path is occupied by another file: the local one yields as a conflict copy
            _ = try await makeRoom(at: row.path, for: row.id)
        }
        try write(remote, to: row.path, record: &r)
        setBase(&r, row, data: remote)
        try state.save(r)
        await hooks.didChange(row.path, nil, remote)
    }

    // MARK: Upload

    /// Returns the number rejected by the server (version mismatch)
    private func push() async throws -> Int {
        var rejected = 0
        // Permanent deletes first, in one request, so a main file and its companion disappear for other devices together
        let purging = state.records.values.filter(\.purgeRequested)
        if !purging.isEmpty {
            let ids = purging.filter { $0.baseVersion != nil }.map(\.id) // Never uploaded: nothing on the server
            if !ids.isEmpty { try await backend.purge(ids: ids, deviceID: deviceID) }
            Self.log.info("purge \(ids.count) files")
            for r in purging { try state.remove(r.id) }
            for r in purging { dropBase(r.baseHash) }
        }
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
                    dropBase(baseHash)
                } else {
                    rejected += 1
                }
                continue
            }
            // It may have been modified again after the scan: upload the latest content on disk
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

    // MARK: Utilities

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

    /// Merge base: look in the local cache first, otherwise download from Storage (content-addressed, old versions always exist)
    private func content(hash: String) async throws -> Data {
        let cached = baseCache.appending(path: hash)
        if let data = try? Data(contentsOf: cached) { return data }
        if let r = state.records.values.first(where: { $0.hash == hash && !$0.localDeleted }),
           let data = try? fs.read(r.path), Self.sha256(data) == hash {
            return data
        }
        let data = try await backend.download(hash: hash)
        guard Self.sha256(data) == hash else { throw HashMismatchError() }
        return data
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

    /// When `path` is occupied by another local file, renames that file to a conflict copy and returns the usable `path`.
    /// Files created after the scan and without a record also count as occupying (the next scan sees the conflict copy as an addition and uploads it)
    private func makeRoom(at path: String, for id: UUID) async throws -> String {
        let occupant = state.record(at: path)
        if let occupant, occupant.id == id { return path }
        guard occupant != nil || fs.exists(path) else { return path }
        let copy = conflictPath(for: path)
        await hooks.willChange(path)
        try FileManager.default.moveItem(at: fs.url(for: path), to: fs.url(for: copy))
        if var occupant {
            occupant.path = copy
            try state.save(occupant)
        }
        status.conflicts.append(copy)
        await hooks.didChange(copy, path, nil)
        return path
    }

    /// A conflict copy is a new file; the next scan treats it as an addition and uploads it; the app is notified (`didChange`) only after the main file is written
    private func writeConflictCopy(of data: Data, for path: String) throws -> String {
        let copy = conflictPath(for: path)
        try fs.write(data, to: copy)
        status.conflicts.append(copy)
        return copy
    }

    func conflictPath(for path: String) -> String {
        fs.conflictPath(for: path, deviceName: deviceName)
    }

    private func hash(of path: String) throws -> String {
        Self.sha256(try fs.read(path))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Unregistered file types (images, PDF…): different content produces a conflict copy
private enum OpaqueKind: DocumentKind {
    static let id = "opaque"
    static let fileExtensions: [String] = []
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
}
