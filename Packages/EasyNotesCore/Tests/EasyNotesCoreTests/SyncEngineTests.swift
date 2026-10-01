import Foundation
import Testing
@testable import EasyNotesCore

/// 以行合併的測試類型（等同 Markdown 外掛的策略），Core 測試不依賴外掛
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

/// 記憶體內的 Supabase：commit 的語意與 `commit_file` RPC 相同
actor FakeBackend: SyncBackend {
    var blobs: [String: Data] = [:]
    var rows: [UUID: RemoteFile] = [:]
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var failNextCommit = false
    var commits = 0

    func upload(_ data: Data, hash: String) async throws { blobs[hash] = data }

    func download(hash: String) async throws -> Data {
        guard let data = blobs[hash] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func commit(_ r: CommitRequest) async throws -> Int? {
        if failNextCommit {
            failNextCommit = false
            throw URLError(.networkConnectionLost)
        }
        let current = rows[r.id]
        guard current?.version == r.baseVersion else { return nil }
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

    func setFailNextCommit() { failNextCommit = true }
}

/// 一台裝置：自己的 Vault 資料夾 + 同步引擎
struct Device {
    let fs: VaultFS
    let engine: SyncEngine

    init(_ name: String, backend: FakeBackend, root: URL? = nil) throws {
        let root = root ?? FileManager.default.temporaryDirectory.appending(path: "sync-\(name)-\(UUID().uuidString)")
        fs = VaultFS(root: root, kinds: try KindRegistry([NoteKind.self]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = try SyncEngine(fs: fs, backend: backend, userID: "me", deviceName: name)
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

    /// 檔案路徑 → 內容；不含 `.easynotes/`
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

    /// 輪流同步直到兩邊一致（最多 3 輪）
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

        try mac.move("舊.note", "資料夾/新.note") // 像 Claude Code 的 mv
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
        try await ipad.engine.moved(from: "a.note", to: "b.note") // App 內改名
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

    @Test func interruptedCommitIsRetried() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("x\n", "a.note")
        await backend.setFailNextCommit()
        await mac.sync()
        #expect(await mac.engine.currentStatus.lastError != nil)
        #expect(await mac.engine.currentStatus.pending == 1)

        // 重新啟動 App：同一個 Vault、新的引擎
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
        let fs = VaultFS(root: root, kinds: try KindRegistry([NoteKind.self]))
        let log = Log()
        let ipad = try SyncEngine(fs: fs, backend: backend, userID: "me", deviceName: "iPad",
                                  hooks: .init(didChange: { path, old, data in await log.add("\(path)|\(old ?? "-")|\(data.map { String(decoding: $0, as: UTF8.self) } ?? "-")") }))
        try mac.write("x\n", "a.note")
        await mac.sync()
        await ipad.sync()
        #expect(await log.items == ["a.note|-|x\n"])
    }
}

actor Log {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
