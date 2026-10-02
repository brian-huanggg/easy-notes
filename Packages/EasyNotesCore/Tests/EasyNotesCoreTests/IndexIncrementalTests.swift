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

/// 外掛決定的 icon、pinned、summary：Core 只存不解讀
private enum FlagKind: DocumentKind {
    static let id = "flag"
    static let fileExtensions = ["flag"]
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry {
        let text = String(decoding: data, as: UTF8.self)
        return IndexEntry(title: fileName, plainText: text, icon: text.contains("🌱") ? "🌱" : nil,
                          pinned: text.contains("pin"), summary: "\(text.count) 字")
    }
}

struct IndexAttributeTests {
    @Test func attributesAreStoredAndUpdated() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "index-\(UUID().uuidString)")
        let fs = VaultFS(root: root, kinds: try KindRegistry([FlagKind.self]))
        try fs.write(Data("pin 🌱".utf8), to: "a.flag")
        try fs.write(Data("plain".utf8), to: "b.flag")
        let index = try VaultIndex(fs: fs)
        try await index.sync()

        let files = Dictionary(uniqueKeysWithValues: try await index.files().map { ($0.path, $0) })
        #expect(files["a.flag"]?.pinned == true)
        #expect(files["a.flag"]?.icon == "🌱")
        #expect(files["a.flag"]?.summary == "5 字")
        #expect(files["b.flag"]?.pinned == false)
        #expect(files["b.flag"]?.icon == nil)
        #expect(files["b.flag"]?.hash == SyncEngine.sha256(Data("plain".utf8)))

        // 外部修改（例如 Claude Code 取消釘選）後增量更新
        // 外部修改（例如 Claude Code 取消釘選）後增量更新
        try fs.write(Data("off".utf8), to: "a.flag")
        try await index.sync(paths: ["a.flag"])
        #expect(try await index.files().first { $0.path == "a.flag" }?.pinned == false)
    }

    @Test func pinningIsUnsupportedByDefault() {
        #expect(FlagKind.setPinned(true, in: Data()) == nil)
        #expect(!FlagKind.supportsPinning)
    }
}
