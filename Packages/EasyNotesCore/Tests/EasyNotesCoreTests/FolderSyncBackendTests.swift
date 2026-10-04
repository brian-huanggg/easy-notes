import EasyNotesTestSupport
import Foundation
import Testing
@testable import EasyNotesCore

/// E2E 測試用的資料夾 backend：commit 語意與 FakeBackend（= `commit_file` RPC）相同
struct FolderSyncBackendTests {
    func makeBackend() throws -> FolderSyncBackend {
        try FolderSyncBackend(root: FileManager.default.temporaryDirectory.appending(path: "folder-backend-\(UUID().uuidString)"))
    }

    func request(_ id: UUID, base: Int?, path: String = "a.note", hash: String = "h", deleted: Bool = false) -> CommitRequest {
        CommitRequest(id: id, baseVersion: base, path: path, hash: hash, size: 1, deleted: deleted, deviceID: "d")
    }

    @Test func commitChecksVersion() async throws {
        let backend = try makeBackend()
        let id = UUID()
        #expect(try await backend.commit(request(id, base: nil)) == 1)
        #expect(try await backend.commit(request(id, base: nil)) == nil)  // 已存在
        #expect(try await backend.commit(request(id, base: 1, hash: "h2")) == 2)
        #expect(try await backend.commit(request(id, base: 1, hash: "h3")) == nil)  // 遠端已變
    }

    @Test func livePathIsUnique() async throws {
        let backend = try makeBackend()
        #expect(try await backend.commit(request(UUID(), base: nil)) == 1)
        #expect(try await backend.commit(request(UUID(), base: nil)) == nil)
        #expect(try await backend.commit(request(UUID(), base: nil, path: "b.note")) == 1)
    }

    @Test func changesAreOrderedAndIncremental() async throws {
        let backend = try makeBackend()
        let a = UUID(), b = UUID()
        _ = try await backend.commit(request(a, base: nil, path: "a.note"))
        _ = try await backend.commit(request(b, base: nil, path: "b.note"))
        let all = try await backend.changes(since: nil)
        #expect(all.map(\.id) == [a, b])
        #expect(try await backend.changes(since: all[0].updatedAt).map(\.id) == [b])
        _ = try await backend.commit(request(a, base: 1, path: "a.note", deleted: true))
        #expect(try await backend.deletedFiles(since: .distantPast).map(\.id) == [a])
    }

    @Test func blobsAreContentAddressed() async throws {
        let backend = try makeBackend()
        try await backend.upload(Data("x".utf8), hash: "k")
        try await backend.upload(Data("y".utf8), hash: "k")  // 只增不覆寫
        #expect(try await backend.download(hash: "k") == Data("x".utf8))
    }

    @Test func twoEnginesConvergeThroughFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "folder-backend-\(UUID().uuidString)")
        func device(_ name: String) throws -> (VaultFS, SyncEngine) {
            let vault = FileManager.default.temporaryDirectory.appending(path: "folder-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
            let fs = VaultFS(root: vault, kinds: try KindRegistry([NoteKind.self]))
            // 每台裝置各自建立 backend，只共用資料夾（等同 App 與測試程序）
            return (fs, try SyncEngine(fs: fs, backend: try FolderSyncBackend(root: root), userID: "me", deviceName: name))
        }
        let (fsA, a) = try device("A")
        let (fsB, b) = try device("B")
        try fsA.write(Data("1\n2\n3\n".utf8), to: "n.note")
        await a.sync()
        await b.sync()
        #expect(try fsB.read("n.note") == Data("1\n2\n3\n".utf8))

        try fsA.write(Data("1a\n2\n3\n".utf8), to: "n.note")
        try fsB.write(Data("1\n2\n3b\n".utf8), to: "n.note")
        await a.sync()
        await b.sync()
        await a.sync()
        #expect(try fsA.read("n.note") == Data("1a\n2\n3b\n".utf8))
        #expect(try fsB.read("n.note") == Data("1a\n2\n3b\n".utf8))
    }
}
