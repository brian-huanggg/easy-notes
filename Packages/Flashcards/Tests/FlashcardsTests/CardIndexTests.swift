import EasyNotesCore
import Foundation
import Testing
@testable import Flashcards

/// Flashcards 不 import Markdown 外掛：用同樣 id 的最小類型代替
private enum NoteKind: DocumentKind {
    static let id = "markdown"
    static let fileExtensions = ["md"]
    static func template(title: String) -> Data { Data("# \(title)\n".utf8) }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
}

struct CardIndexTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "cards-\(UUID().uuidString)")
    var fs: VaultFS { VaultFS(root: root, kinds: try! KindRegistry([NoteKind.self])) }

    /// App 的流程：外部寫入 → 索引 → ContentFixer 補 id → 寫回 → 索引
    func fix(_ path: String, _ index: VaultIndex) async throws -> Bool {
        guard let data = await CardIDFixer().fix(path: path, kindID: "markdown", data: try fs.read(path), index: index) else {
            return false
        }
        try fs.write(data, to: path)
        try await index.update(path, data: data)
        return true
    }

    /// 驗收：Claude Code 寫入 50 行 `::` 卡片 → 全部補上 `^id`，其餘內容逐位元組相同
    @Test func fiftyCardsFromClaudeCode() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...50).map { "- 單字 \($0) :: word \($0)" }
        let original = "# 單字\n\n" + lines.joined(separator: "\n") + "\n"
        try fs.write(Data(original.utf8), to: "英文/單字.md")
        let index = try VaultIndex(fs: fs, contributors: [CardIndexer()])
        try await index.sync()
        #expect(try await CardIndexer.notes(in: index).isEmpty) // 還沒有 id 的卡片不進索引

        #expect(try await fix("英文/單字.md", index))
        let fixed = String(decoding: try fs.read("英文/單字.md"), as: UTF8.self)
        let stripped = fixed.replacing(/\s\^c-[0-9a-z]{6}/, with: "")
        #expect(stripped == original)

        let notes = try await CardIndexer.notes(in: index)
        #expect(notes.count == 50)
        #expect(Set(notes.compactMap(\.note.id)).count == 50)
        #expect(notes.allSatisfy { $0.path == "英文/單字.md" })
        #expect(try await !fix("英文/單字.md", index)) // 第二次不需要修改
    }

    /// 複製到另一篇：新位置換 id，原本的保留
    @Test func copiedCardGetsNewIDInNewFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try fs.write(Data("問 :: 答 ^c-aaaaaa\n".utf8), to: "a.md")
        try fs.write(Data("問 :: 答 ^c-aaaaaa\n".utf8), to: "b.md")
        let index = try VaultIndex(fs: fs, contributors: [CardIndexer()])
        try await index.sync()
        #expect(try await fix("b.md", index))
        #expect(try await !fix("a.md", index))
        let ids = try await CardIndexer.notes(in: index).map { "\($0.path) \($0.note.id!)" }
        #expect(ids.count == 2)
        #expect(ids.contains("a.md c-aaaaaa"))
    }

    /// 整行搬到別篇（原本那篇已刪掉這一行）：id 不變
    @Test func movedCardKeepsID() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try fs.write(Data("問 :: 答 ^c-aaaaaa\n".utf8), to: "a.md")
        let index = try VaultIndex(fs: fs, contributors: [CardIndexer()])
        try await index.sync()
        try fs.write(Data("其他\n".utf8), to: "a.md")
        try fs.write(Data("問 :: 答 ^c-aaaaaa\n".utf8), to: "b.md")
        try await index.sync(paths: ["a.md", "b.md"])
        #expect(try await !fix("b.md", index))
        #expect(try await index.paths(withKey: "c-aaaaaa", contributor: "cards") == ["b.md"])
    }
}
