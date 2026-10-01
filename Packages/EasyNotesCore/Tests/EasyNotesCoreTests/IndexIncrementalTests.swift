import Foundation
import Testing
@testable import EasyNotesCore

/// VaultWatcher 只重掃事件帶來的路徑，不再對整個 Vault 做 stat
struct IndexIncrementalTests {
    func makeIndex() async throws -> (VaultFS, VaultIndex) {
        let root = FileManager.default.temporaryDirectory.appending(path: "index-\(UUID().uuidString)")
        let fs = VaultFS(root: root, kinds: try KindRegistry([TextKind.self]))
        for i in 0..<200 { try fs.write(Data("檔案 \(i)\n".utf8), to: "資料夾\(i % 4)/\(i).txt") }
        let index = try VaultIndex(fs: fs)
        try #require(try await index.sync().count == 200)
        return (fs, index)
    }

    @Test func onlyEventPathsAreReindexed() async throws {
        let (fs, index) = try await makeIndex()
        let edited = (0..<50).map { "資料夾\($0 % 4)/\($0).txt" }
        for path in edited { try fs.write(Data("Claude 改過 \(path)\n".utf8), to: path) }

        // 事件也包含沒變的檔案與 .easynotes 以外的雜訊：只回報真的變動的 50 個
        let changed = try await index.sync(paths: Set(edited + ["資料夾0/100.txt", "不存在.txt"]))
        #expect(changed == Set(edited))
        #expect(try await index.search("Claude 改過").count == 50)
    }

    @Test func deletedAndMovedFoldersAreHandled() async throws {
        let (fs, index) = try await makeIndex()
        try FileManager.default.moveItem(at: fs.url(for: "資料夾1"), to: fs.url(for: "新資料夾"))
        let changed = try await index.sync(paths: ["資料夾1", "新資料夾"])
        #expect(changed.count == 100) // 50 個移除 + 50 個新增
        #expect(try await index.sync().isEmpty) // 與完整掃描一致
    }

    @Test func unregisteredFilesAreIgnored() async throws {
        let (fs, index) = try await makeIndex()
        try fs.write(Data("x".utf8), to: "圖.png")
        #expect(try await index.sync(paths: ["圖.png"]).isEmpty)
    }
}
