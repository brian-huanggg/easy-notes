import Foundation
import Testing
@testable import EasyNotesCore

/// A line-merging test type (equivalent to the Markdown plugin's strategy); Core tests depend on no plugin
enum NoteKind: DocumentKind {
    static let id = "note"
    static let fileExtensions = ["note"]
    static func template(title: String) -> Data { Data("\(title)\n".utf8) }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
    static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        guard let base else { return local == remote ? local : nil }
        return Diff3.merge(base: base, local: local, remote: remote)
    }
}

/// An in-memory Supabase: commit semantics match the `commit_file` RPC
actor FakeBackend: SyncBackend {
    var blobs: [String: Data] = [:]
    var rows: [UUID: RemoteFile] = [:]
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var failNextCommit = false
    var commits = 0
    /// Called on download: simulates the user typing and autosaving in the editor during the download (network)
    var onDownload: (@Sendable (String) -> Void)?

    func upload(_ data: Data, hash: String) async throws { blobs[hash] = data }

    func download(hash: String) async throws -> Data {
        onDownload?(hash)
        guard let data = blobs[hash] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func commit(_ r: CommitRequest) async throws -> Int? {
        if failNextCommit {
            failNextCommit = false
            throw URLError(.networkConnectionLost)
        }
        let current = rows[r.id]
        guard current?.version == r.baseVersion, current?.purged != true else { return nil }
        if !r.deleted, rows.values.contains(where: { $0.id != r.id && $0.path == r.path && !$0.deleted }) { return nil }
        clock += 1
        let version = (current?.version ?? 0) + 1
        rows[r.id] = RemoteFile(id: r.id, path: r.path, hash: r.hash, size: r.size, version: version,
                                deleted: r.deleted, deviceID: r.deviceID, updatedAt: clock)
        commits += 1
        return version
    }

    func changes(since cursor: Date?) async throws -> [RemoteFile] {
        rows.values.filter { $0.updatedAt > cursor ?? .distantPast }.sorted { $0.updatedAt < $1.updatedAt }
    }

    func deletedFiles(since: Date) async throws -> [RemoteFile] {
        rows.values.filter { $0.deleted && !$0.purged }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var purges = 0

    /// Like the `purge_files` RPC: tombstones the rows, then drops blobs no remaining row references
    func purge(ids: [UUID], deviceID: String) async throws {
        purges += 1
        var freed: [String] = []
        for id in ids {
            guard let row = rows[id], !row.purged else { continue }
            freed.append(row.hash)
            clock += 1
            rows[id] = RemoteFile(id: id, path: id.uuidString, hash: "", size: 0, version: row.version + 1, deleted: true,
                                  purged: true, deviceID: deviceID, updatedAt: clock)
        }
        for hash in freed where !rows.values.contains(where: { $0.hash == hash }) { blobs[hash] = nil }
    }

    func setFailNextCommit() { failNextCommit = true }
    func setOnDownload(_ f: (@Sendable (String) -> Void)?) { onDownload = f }
}

/// One device: its own vault folder + sync engine
struct Device {
    let fs: VaultFS
    let engine: SyncEngine

    init(_ name: String, backend: FakeBackend, root: URL? = nil, metaFolders: [String] = []) throws {
        let root = root ?? FileManager.default.temporaryDirectory.appending(path: "sync-\(name)-\(UUID().uuidString)")
        fs = VaultFS(root: root, kinds: try KindRegistry([NoteKind.self, AnnotationKind.self]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = try SyncEngine(fs: fs, backend: backend, userID: "me", deviceName: name, syncedMetaFolders: metaFolders)
    }

    func write(_ text: String, _ path: String) throws { try fs.write(Data(text.utf8), to: path) }
    func read(_ path: String) -> String? { (try? fs.read(path)).map { String(decoding: $0, as: UTF8.self) } }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: fs.url(for: path).path(percentEncoded: false)) }
    func move(_ from: String, _ to: String) throws {
        let target = fs.url(for: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fs.url(for: from), to: target)
    }
    func delete(_ path: String) throws { try FileManager.default.removeItem(at: fs.url(for: path)) }

    /// File path → content; excludes `.easynotes/`
    func snapshot() throws -> [String: String] {
        var result: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: fs.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result[fs.path(for: url)] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            }
        }
        return result
    }

    func sync() async { await engine.sync() }
}

struct SyncEngineTests {
    let backend = FakeBackend()

    /// Syncs in turns until both sides agree (at most 3 rounds)
    func converge(_ a: Device, _ b: Device) async throws {
        for _ in 0..<3 {
            await a.sync()
            await b.sync()
            if try a.snapshot() == b.snapshot() { return }
        }
    }

    @Test func newFileReachesOtherDevice() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("# 筆記\n", "資料夾/筆記.note")
        await mac.sync()
        await ipad.sync()
        #expect(ipad.read("資料夾/筆記.note") == "# 筆記\n")
        #expect(await backend.rows.count == 1)
        #expect(await mac.engine.currentStatus.pending == 0)
        #expect(await ipad.engine.currentStatus.pending == 0)
    }

    @Test func offlineEditsOnDifferentParagraphsConverge() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("一\n\n二\n\n三\n", "a.note")
        try await converge(mac, ipad)

        try mac.write("一（Mac）\n\n二\n\n三\n", "a.note")
        try ipad.write("一\n\n二\n\n三（iPad）\n", "a.note")
        try await converge(mac, ipad)

        #expect(mac.read("a.note") == "一（Mac）\n\n二\n\n三（iPad）\n")
        #expect(try mac.snapshot() == ipad.snapshot())
        #expect(await mac.engine.currentStatus.conflicts.isEmpty)
    }

    @Test func overlappingEditsProduceConflictCopy() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("同一行\n", "a.note")
        try await converge(mac, ipad)

        try mac.write("Mac 版\n", "a.note")
        try ipad.write("iPad 版\n", "a.note")
        await mac.sync()
        await ipad.sync()
        try await converge(mac, ipad)

        let files = try ipad.snapshot()
        #expect(files["a.note"] == "Mac 版\n")
        let copy = try #require(files.keys.first { $0.hasPrefix("a (衝突 iPad ") && $0.hasSuffix(").note") })
        #expect(files[copy] == "iPad 版\n")
        #expect(try mac.snapshot() == files)
    }

    /// No local change when sync starts, and a save during the download of the remote version: that change must be merged in and not overwritten by remote content
    @Test func editSavedDuringDownloadIsMerged() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("一\n\n二\n", "a.note")
        try await converge(mac, ipad)

        try mac.write("一（Mac）\n\n二\n", "a.note")
        await mac.sync()
        let file = ipad.fs.url(for: "a.note")
        await backend.setOnDownload { _ in try? Data("一\n\n二（iPad）\n".utf8).write(to: file) }
        await ipad.sync()
        await backend.setOnDownload(nil)

        #expect(ipad.read("a.note") == "一（Mac）\n\n二（iPad）\n")
        try await converge(mac, ipad)
        #expect(mac.read("a.note") == "一（Mac）\n\n二（iPad）\n")
        #expect(await ipad.engine.currentStatus.conflicts.isEmpty)
    }

    /// After the scan and before applying a remote new file, local created a file at the same path (for example both sides add "Untitled" at once): it must not be overwritten
    @Test func localFileCreatedDuringPullIsNotOverwritten() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("Mac\n", "a.note")
        await mac.sync()
        let file = ipad.fs.url(for: "a.note")
        await backend.setOnDownload { _ in try? Data("iPad\n".utf8).write(to: file) }
        await ipad.sync()
        await backend.setOnDownload(nil)
        try await converge(mac, ipad)

        let files = try ipad.snapshot()
        #expect(files["a.note"] == "Mac\n")
        let copy = try #require(files.keys.first { $0.hasPrefix("a (衝突 iPad ") && $0.hasSuffix(").note") })
        #expect(files[copy] == "iPad\n")
        #expect(try mac.snapshot() == files)
    }

    /// Three devices each edit a different paragraph of the same note offline → after reconnecting the content agrees and there are no conflict copies
    @Test func threeDevicesOfflineEditsConverge() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        let iphone = try Device("iPhone", backend: backend)
        try mac.write("一\n\n二\n\n三\n", "a.note")
        for _ in 0..<2 { for d in [mac, ipad, iphone] { await d.sync() } }

        try mac.write("一（Mac）\n\n二\n\n三\n", "a.note")
        try ipad.write("一\n\n二（iPad）\n\n三\n", "a.note")
        try iphone.write("一\n\n二\n\n三（iPhone）\n", "a.note")
        for _ in 0..<3 { for d in [mac, ipad, iphone] { await d.sync() } }

        let expected = ["a.note": "一（Mac）\n\n二（iPad）\n\n三（iPhone）\n"]
        #expect(try mac.snapshot() == expected)
        #expect(try ipad.snapshot() == expected)
        #expect(try iphone.snapshot() == expected)
        for d in [mac, ipad, iphone] { #expect(await d.engine.currentStatus.pending == 0) }
    }

    @Test func binaryConflictKeepsBoth() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("v1", "圖.png")
        try await converge(mac, ipad)
        try mac.write("mac", "圖.png")
        try ipad.write("ipad", "圖.png")
        await mac.sync()
        await ipad.sync()
        try await converge(mac, ipad)
        let files = try mac.snapshot()
        #expect(files.count == 2)
        #expect(files.keys.contains { $0.hasPrefix("圖 (衝突 iPad ") && $0.hasSuffix(").png") })
    }

    @Test func externalRenameKeepsFileID() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("內容\n", "舊.note")
        try await converge(mac, ipad)
        let id = try #require(await backend.rows.keys.first)

        try mac.move("舊.note", "資料夾/新.note") // Like Claude Code's mv
        try await converge(mac, ipad)

        #expect(await backend.rows.count == 1)
        #expect(await backend.rows[id]?.path == "資料夾/新.note")
        #expect(!ipad.exists("舊.note"))
        #expect(ipad.read("資料夾/新.note") == "內容\n")
    }

    @Test func renameOnOneDeviceAndEditOnOtherKeepsBoth() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("一\n\n二\n", "a.note")
        try await converge(mac, ipad)

        try ipad.move("a.note", "b.note")
        try await ipad.engine.moved(from: "a.note", to: "b.note") // In-app rename
        try mac.write("一\n\n二（Mac 改）\n", "a.note")
        await ipad.sync()
        await mac.sync()
        try await converge(mac, ipad)

        #expect(try mac.snapshot() == ["b.note": "一\n\n二（Mac 改）\n"])
        #expect(try ipad.snapshot() == ["b.note": "一\n\n二（Mac 改）\n"])
    }

    @Test func deleteReachesOtherDeviceAsSoftDelete() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("x\n", "a.note")
        try await converge(mac, ipad)
        try mac.delete("a.note")
        try await converge(mac, ipad)
        #expect(!ipad.exists("a.note"))
        #expect(await backend.rows.values.first?.deleted == true)
    }

    @Test func editBeatsRemoteDelete() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("x\n", "a.note")
        try await converge(mac, ipad)
        try mac.delete("a.note")
        try ipad.write("x 改\n", "a.note")
        await mac.sync()
        await ipad.sync()
        try await converge(mac, ipad)
        #expect(mac.read("a.note") == "x 改\n")
        #expect(await backend.rows.values.first?.deleted == false)
    }

    @Test func deletedFileCanBeRestoredOnAnyDevice() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("重要內容\n", "a.note")
        try await converge(mac, ipad)
        let id = try #require(await backend.rows.keys.first)
        try mac.delete("a.note")
        try await converge(mac, ipad)
        #expect(!ipad.exists("a.note"))

        // iPad restores from "Recently Deleted": the same file id, and Mac gets it back too
        let deleted = try await ipad.engine.recentlyDeleted()
        #expect(deleted.map(\.id) == [id])
        #expect(try await ipad.engine.restore(deleted[0]) == "a.note")
        #expect(ipad.read("a.note") == "重要內容\n")
        #expect(try await ipad.engine.recentlyDeleted().isEmpty)
        try await converge(mac, ipad)
        #expect(mac.read("a.note") == "重要內容\n")
        #expect(await backend.rows[id]?.deleted == false)
        #expect(await backend.rows.count == 1)
    }

    @Test func restoreIntoOccupiedPathUsesConflictName() async throws {
        let mac = try Device("Mac", backend: backend)
        try mac.write("舊\n", "a.note")
        await mac.sync()
        try mac.delete("a.note")
        await mac.sync()
        try mac.write("新\n", "a.note")
        await mac.sync()
        let deleted = try #require(try await mac.engine.recentlyDeleted().first)
        let path = try await mac.engine.restore(deleted)
        #expect(path.hasPrefix("a (衝突 Mac "))
        #expect(mac.read(path) == "舊\n")
        #expect(mac.read("a.note") == "新\n")
        await mac.sync()
        #expect(await mac.engine.currentStatus.pending == 0)
    }

    // MARK: Permanent delete

    @Test func hardDeleteReachesOtherDeviceAndLeavesNothingBehind() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("機密\n", "a.note")
        try mac.write("留著\n", "b.note")
        try await converge(mac, ipad)
        let id = try #require(await backend.rows.values.first { $0.path == "a.note" }?.id)

        try await mac.engine.requestPurge("a.note")
        try mac.delete("a.note")
        try await converge(mac, ipad)

        #expect(!ipad.exists("a.note"))
        #expect(ipad.read("b.note") == "留著\n")
        let row = try #require(await backend.rows[id])
        #expect(row.purged && row.deleted && row.hash.isEmpty && row.path != "a.note")
        // Only the other file's content is left on the server; nothing lists the purged one
        #expect(await backend.blobs.count == 1)
        #expect(try await mac.engine.recentlyDeleted().isEmpty)
        #expect(try await ipad.engine.recentlyDeleted().isEmpty)
        #expect(await mac.engine.currentStatus.pending == 0)
        #expect(await ipad.engine.currentStatus.pending == 0)
    }

    @Test func hardDeleteQueuedOfflineSurvivesRestart() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("x\n", "a.note")
        try await converge(mac, ipad)

        try await mac.engine.requestPurge("a.note")
        try mac.delete("a.note")
        // The app quits before it ever syncs: the intent must not degrade to a soft delete
        let restarted = try Device("Mac", backend: backend, root: mac.fs.root)
        await restarted.sync()
        await ipad.sync()

        #expect(await backend.rows.values.allSatisfy { $0.purged })
        #expect(!ipad.exists("a.note"))
        #expect(try await ipad.engine.recentlyDeleted().isEmpty)
    }

    @Test func hardDeletedFileIsNotMistakenForARename() async throws {
        let mac = try Device("Mac", backend: backend)
        try mac.write("x\n", "a.note")
        await mac.sync()
        let id = try #require(await backend.rows.keys.first)

        try await mac.engine.requestPurge("a.note")
        try mac.delete("a.note")
        try mac.write("x\n", "b.note") // Same content appears elsewhere: a new file, not the old one moved
        await mac.sync()

        #expect(await backend.rows[id]?.purged == true)
        let live = await backend.rows.values.filter { !$0.deleted }
        #expect(live.map(\.path) == ["b.note"])
        #expect(live.first?.id != id)
    }

    @Test func purgeSharedContentKeepsBlobForTheOtherFile() async throws {
        let mac = try Device("Mac", backend: backend)
        try mac.write("same\n", "a.note")
        try mac.write("same\n", "b.note")
        await mac.sync()
        #expect(await backend.blobs.count == 1)

        try await mac.engine.requestPurge("a.note")
        try mac.delete("a.note")
        await mac.sync()
        #expect(await backend.blobs.count == 1)
        #expect(mac.read("b.note") == "same\n")
    }

    @Test func hardDeleteOfFolderPurgesEveryFileInside() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("1\n", "資料夾/a.note")
        try mac.write("2\n", "資料夾/b.note")
        try mac.write("3\n", "c.note")
        try await converge(mac, ipad)

        #expect(try await mac.engine.requestPurge("資料夾") == ["資料夾/a.note", "資料夾/b.note"])
        try mac.fs.deleteImmediately("資料夾")
        try await converge(mac, ipad)

        #expect(try ipad.snapshot() == ["c.note": "3\n"])
        #expect(await backend.rows.values.filter(\.purged).count == 2)
        #expect(await backend.blobs.count == 1)
    }

    @Test func emptyTrashPurgesEverythingDeleted() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("1\n", "a.note")
        try mac.write("2\n", "b.note")
        try mac.write("3\n", "keep.note")
        try await converge(mac, ipad)
        try mac.delete("a.note")
        try mac.delete("b.note")
        try await converge(mac, ipad)
        #expect(try await ipad.engine.recentlyDeleted().count == 2)

        #expect(try await ipad.engine.purgeAllDeleted() == 2)
        #expect(try await mac.engine.recentlyDeleted().isEmpty)
        #expect(try await ipad.engine.purgeAllDeleted() == 0)
        try await converge(mac, ipad)
        #expect(try mac.snapshot() == ["keep.note": "3\n"])
        #expect(await backend.rows.values.filter(\.purged).count == 2)
        #expect(await backend.blobs.count == 1)
    }

    @Test func purgedFileCannotBeRestoredOrRecommitted() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("x\n", "a.note")
        try await converge(mac, ipad)
        try mac.delete("a.note")
        try await converge(mac, ipad)
        let stale = try #require(try await ipad.engine.recentlyDeleted().first) // iPad opens the list...
        try await mac.engine.purge(stale)                                       // ...Mac empties it meanwhile

        // The content is gone with it, so the restore fails before it can commit
        await #expect(throws: (any Error).self) { try await ipad.engine.restore(stale) }
        let request = CommitRequest(id: stale.id, baseVersion: stale.version + 1, path: "a.note", hash: "h", size: 1,
                                    deleted: false, deviceID: "x")
        #expect(try await backend.commit(request) == nil)
    }

    @Test func editedOnAnotherDeviceBeatsPurge() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("x\n", "a.note")
        try await converge(mac, ipad)
        let id = try #require(await backend.rows.keys.first)

        try await mac.engine.requestPurge("a.note")
        try mac.delete("a.note")
        await mac.sync()
        try ipad.write("x 改\n", "a.note") // Unsynced work on the iPad is never destroyed by a remote purge
        await ipad.sync()

        #expect(ipad.read("a.note") == "x 改\n")
        #expect(await backend.rows[id]?.purged == true)
        let live = await backend.rows.values.filter { !$0.deleted }
        #expect(live.map(\.path) == ["a.note"])
        #expect(live.first?.id != id)
        #expect(await ipad.engine.currentStatus.pending == 0)
    }

    @Test func interruptedCommitIsRetried() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("x\n", "a.note")
        await backend.setFailNextCommit()
        await mac.sync()
        #expect(await mac.engine.currentStatus.lastError != nil)
        #expect(await mac.engine.currentStatus.pending == 1)

        // Relaunch the app: the same vault, a new engine
        let restarted = try Device("Mac", backend: backend, root: mac.fs.root)
        await restarted.sync()
        await ipad.sync()
        #expect(ipad.read("a.note") == "x\n")
        #expect(await restarted.engine.currentStatus.pending == 0)
    }

    @Test func identicalFilesCreatedOnBothDevicesAreAdopted() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("範例\n", "歡迎.note")
        try ipad.write("範例\n", "歡迎.note")
        try await converge(mac, ipad)
        #expect(await backend.rows.count == 1)
        #expect(try ipad.snapshot() == ["歡迎.note": "範例\n"])
    }

    @Test func differentFilesAtSamePathProduceConflictCopy() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("Mac\n", "a.note")
        try ipad.write("iPad\n", "a.note")
        try await converge(mac, ipad)
        #expect(await backend.rows.count == 2)
        #expect(try mac.snapshot().count == 2)
        #expect(try mac.snapshot() == ipad.snapshot())
    }

    @Test func unchangedFilesAreNotRecommitted() async throws {
        let mac = try Device("Mac", backend: backend)
        try mac.write("x\n", "a.note")
        await mac.sync()
        await mac.sync()
        await mac.sync()
        #expect(await backend.commits == 1)
    }

    @Test func remoteChangeNotifiesHooks() async throws {
        let mac = try Device("Mac", backend: backend)
        let root = FileManager.default.temporaryDirectory.appending(path: "sync-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = VaultFS(root: root, kinds: try KindRegistry([NoteKind.self, AnnotationKind.self]))
        let log = Log()
        let ipad = try SyncEngine(fs: fs, backend: backend, userID: "me", deviceName: "iPad",
                                  hooks: .init(didChange: { path, old, data in await log.add("\(path)|\(old ?? "-")|\(data.map { String(decoding: $0, as: UTF8.self) } ?? "-")") }))
        try mac.write("x\n", "a.note")
        await mac.sync()
        await ipad.sync()
        #expect(await log.items == ["a.note|-|x\n"])
    }
}

/// Only registered subfolders of `.easynotes/` take part in sync; device-id is local
struct SyncMetaFolderTests {
    let backend = FakeBackend()

    @Test func registeredMetaFolderSyncs() async throws {
        let mac = try Device("Mac", backend: backend, metaFolders: ["srs"])
        let ipad = try Device("iPad", backend: backend, metaFolders: ["srs"])
        try mac.write("{\"id\":1}\n", ".easynotes/srs/mac.jsonl")
        try mac.write("local", ".easynotes/cache/index.sqlite")
        try mac.write("", ".easynotes/seeded")
        try mac.write("# 筆記\n", "筆記.note")
        await mac.sync()
        let paths = Set(await backend.rows.values.map(\.path))
        #expect(paths == [".easynotes/srs/mac.jsonl", "筆記.note"])

        await ipad.sync()
        #expect(ipad.read(".easynotes/srs/mac.jsonl") == "{\"id\":1}\n")
        #expect(!ipad.exists(".easynotes/seeded"))

        // Appended logs sync too; iPad writes its own file, so no conflict
        try mac.write("{\"id\":1}\n{\"id\":2}\n", ".easynotes/srs/mac.jsonl")
        try ipad.write("{\"id\":3}\n", ".easynotes/srs/ipad.jsonl")
        await mac.sync()
        await ipad.sync()
        await mac.sync()
        #expect(ipad.read(".easynotes/srs/mac.jsonl") == "{\"id\":1}\n{\"id\":2}\n")
        #expect(mac.read(".easynotes/srs/ipad.jsonl") == "{\"id\":3}\n")
        #expect(await mac.engine.currentStatus.conflicts.isEmpty)
        #expect(await ipad.engine.currentStatus.conflicts.isEmpty)
    }

    @Test func unregisteredMetaFolderStaysLocal() async throws {
        let mac = try Device("Mac", backend: backend)
        try mac.write("{}\n", ".easynotes/srs/mac.jsonl")
        await mac.sync()
        #expect(await backend.rows.isEmpty)
    }

    @Test func deviceIDIsStoredInMetaFolderAndNotSynced() async throws {
        let mac = try Device("Mac", backend: backend, metaFolders: ["srs"])
        let id = await mac.engine.deviceID
        #expect(try mac.fs.deviceID() == id)
        #expect(mac.read(".easynotes/device-id") == id + "\n")
        await mac.sync()
        #expect(await backend.rows.isEmpty)

        // Recreating the engine (app relaunch) leaves the id unchanged
        let again = try SyncEngine(fs: mac.fs, backend: backend, userID: "me", deviceName: "Mac")
        #expect(await again.deviceID == id)
    }

    @Test func deviceIDMigratesFromSyncState() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "device-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = VaultFS(root: root, kinds: try KindRegistry([NoteKind.self, AnnotationKind.self]))
        #expect(try fs.deviceID(migrating: "OLD-ID") == "OLD-ID")
        #expect(try fs.deviceID(migrating: "OTHER") == "OLD-ID") // Already exists, so not overwritten
        try FileManager.default.removeItem(at: fs.url(for: ".easynotes/device-id"))
        let fresh = try fs.deviceID()
        #expect(fresh != "OLD-ID" && !fresh.isEmpty)
    }
}

actor Log {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
