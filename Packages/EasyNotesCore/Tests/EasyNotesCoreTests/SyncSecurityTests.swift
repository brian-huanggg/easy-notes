import Foundation
import Testing
@testable import EasyNotesCore

extension FakeBackend {
    func plant(_ row: RemoteFile, blob: Data) { rows[row.id] = row; blobs[row.hash] = blob }
    func tamper(hash: String, with data: Data) { blobs[hash] = data }
}

/// 同步不信任遠端：路徑要留在 Vault 內、下載的內容要符合 hash（見 security.md 不變條件 1、2）
struct SyncSecurityTests {
    let backend = FakeBackend()

    @Test(arguments: ["../evil.note", "/etc/evil.note", "a/../../evil.note", "a//b.note", "./a.note", "a\\b.note"])
    func unsafeRemotePathIsNotApplied(_ path: String) async throws {
        let device = try Device("Mac", backend: backend)
        let data = Data("x\n".utf8)
        let hash = SyncEngine.sha256(data)
        await backend.plant(RemoteFile(id: UUID(), path: path, hash: hash, size: data.count, version: 1,
                                       deleted: false, deviceID: "evil", updatedAt: Date(timeIntervalSince1970: 2_000_000)),
                            blob: data)
        await device.sync()

        #expect(try device.snapshot().isEmpty)
        let outside = device.fs.root.deletingLastPathComponent().appending(path: "evil.note")
        #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
    }

    @Test func tamperedBlobIsRejected() async throws {
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("原文\n", "a.note")
        await mac.sync()
        let row = try #require(await backend.rows.values.first)
        await backend.tamper(hash: row.hash, with: Data("被竄改\n".utf8))

        await ipad.sync()

        #expect(!ipad.exists("a.note"))
        #expect(await ipad.engine.currentStatus.lastError != nil)
    }

    @Test func safePathRules() {
        #expect(VaultFS.isSafe(path: "資料夾/筆記.md"))
        #expect(VaultFS.isSafe(path: ".easynotes/srs/dev.jsonl"))
        #expect(!VaultFS.isSafe(path: ""))
        #expect(!VaultFS.isSafe(path: "a/.."))
        #expect(!VaultFS.isSafe(path: "a/\0b"))
    }
}

/// 新檔案的標題來自 `[[連結]]`，不能讓檔名離開 Vault（security.md 不變條件 1）
struct VaultCreateSecurityTests {
    @Test func linkTitleCannotEscapeVault() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "create-\(UUID().uuidString)")
        let fs = VaultFS(root: root, kinds: try KindRegistry([NoteKind.self]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for title in ["../../evil", "/etc/evil", "..", "a/b", "   "] {
            let path = try fs.create(kind: NoteKind.self, title: title)
            #expect(VaultFS.isSafe(path: path), "\(title) → \(path)")
            #expect(!path.contains("/"))
            #expect(fs.url(for: path).deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        }
        #expect(VaultFS.safeFileName("日常/筆記") == "日常-筆記")
    }
}
