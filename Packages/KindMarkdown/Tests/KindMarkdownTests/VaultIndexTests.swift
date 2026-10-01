import Foundation
import Testing
@testable import EasyNotesCore
@testable import KindMarkdown

/// 外掛之間不互相 import：用一個沒有內文的類型代替白板
private enum SketchKind: DocumentKind {
    static let id = "sketch"
    static let fileExtensions = ["sketch"]
    static func template(title: String) -> Data { Data("{}".utf8) }
    static func index(_ data: Data, fileName: String) -> IndexEntry {
        IndexEntry(title: (fileName as NSString).deletingPathExtension, plainText: "")
    }
}

struct VaultIndexTests {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var fs: VaultFS { VaultFS(root: root, kinds: try! KindRegistry([MarkdownKind.self, SketchKind.self])) }

    func write(_ path: String, _ text: String) throws {
        try fs.write(Data(text.utf8), to: path)
    }

    func makeVault() throws -> VaultIndex {
        try write("生物/葉綠體.md", "# 葉綠體\n行光合作用的胞器。\n#生物/植物")
        try write("生物/光合作用.md", "# 光合作用\n發生在 [[葉綠體]]，產生葡萄糖。\n#生物")
        try write("日記.md", "今天讀了 [[葉綠體|綠色的那個]] 和 [[不存在]]。")
        try fs.write(SketchKind.template(title: "草稿"), to: "草稿.sketch")
        return try VaultIndex(fs: fs)
    }

    @Test func fullTextSearchHandlesChinese() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try makeVault()
        #expect(try await index.sync().count == 4)

        // ≥3 字：FTS5 trigram MATCH，命中文字以標記包住
        let hits = try await index.search("光合作用")
        #expect(Set(hits.map(\.path)) == ["生物/葉綠體.md", "生物/光合作用.md"])
        #expect(hits.allSatisfy { $0.snippet.contains("\u{1}光合作用\u{2}") })
        #expect(hits.allSatisfy { !$0.snippet.contains("[[") && !$0.snippet.hasPrefix("#") })

        // <3 字：LIKE 後援
        #expect(try await index.search("胞器").map(\.path) == ["生物/葉綠體.md"])
        // 多詞 AND
        #expect(try await index.search("葡萄糖 葉綠體").map(\.path) == ["生物/光合作用.md"])
    }

    @Test func backlinksTagsAndTargets() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try makeVault()
        try await index.sync()

        let back = try await index.backlinks(to: "生物/葉綠體.md")
        #expect(back.map(\.path).sorted() == ["日記.md", "生物/光合作用.md"])
        // 片段去掉語法、顯示別名
        #expect(back.first { $0.path == "日記.md" }?.snippet == "今天讀了 \u{1}綠色的那個\u{2} 和 不存在。")
        #expect(back.first { $0.path == "生物/光合作用.md" }?.snippet == "發生在 \u{1}葉綠體\u{2}，產生葡萄糖。")

        #expect(try await index.tags().map(\.tag) == ["生物", "生物/植物"])
        #expect(Set(try await index.search("#生物").map(\.path)) == ["生物/葉綠體.md", "生物/光合作用.md"])
        #expect(try await index.linkTargets().contains("草稿"))
    }

    @Test func incrementalSync() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try makeVault()
        try await index.sync()
        #expect(try await index.sync().isEmpty)

        try await Task.sleep(for: .milliseconds(20))
        try write("日記.md", "改寫了，現在提到粒線體")
        try FileManager.default.removeItem(at: fs.url(for: "草稿.sketch"))
        #expect(try await index.sync() == ["日記.md", "草稿.sketch"])
        #expect(try await index.search("粒線體").map(\.path) == ["日記.md"])
        #expect(try await index.backlinks(to: "生物/葉綠體.md").map(\.path) == ["生物/光合作用.md"])
    }

    @Test func renameLinksKeepsAliasAndEmbeds() {
        let text = "見 [[葉綠體]]、[[葉綠體|綠色]]、![[葉綠體]]、[[葉綠體素]]"
        #expect(MarkdownKind.renameLinks(in: text, from: "葉綠體", to: "Chloroplast")
            == "見 [[Chloroplast]]、[[Chloroplast|綠色]]、![[Chloroplast]]、[[葉綠體素]]")
        #expect(MarkdownKind.renameLinks(in: Data(text.utf8), from: "不存在", to: "x") == nil)
    }
}
