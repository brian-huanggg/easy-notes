import Foundation
import Testing
import EasyNotesCore
@testable import KindMarkdown

struct MarkdownIndexTests {
    @Test func extractsTitleLinksAndTags() {
        let md = """
        ---
        created: 2026-10-01
        ---
        # 光合作用
        參考 [[葉綠體]] 與 [[細胞|細胞結構]]，#生物 #biology/plant
        再提一次 [[葉綠體]]
        """
        let entry = MarkdownKind.index(Data(md.utf8), fileName: "note.md")
        #expect(entry.title == "光合作用")
        #expect(entry.links == ["葉綠體", "細胞"])
        #expect(entry.tags == ["生物", "biology/plant"])
        #expect(!entry.plainText.contains("created:"))
    }

    @Test func fallsBackToFileName() {
        let entry = MarkdownKind.index(Data("沒有標題".utf8), fileName: "隨手記.md")
        #expect(entry.title == "隨手記")
    }
}

struct MarkdownMergeTests {
    @Test func mergesNonOverlappingEdits() throws {
        let base = Data("# A\n\n一\n\n二\n".utf8)
        let merged = try #require(MarkdownKind.merge(base: base, local: Data("# A\n\n一改\n\n二\n".utf8),
                                                     remote: Data("# A\n\n一\n\n二改\n".utf8)))
        #expect(String(decoding: merged, as: UTF8.self) == "# A\n\n一改\n\n二改\n")
    }

    @Test func withoutBaseOnlyIdenticalContentMerges() {
        #expect(MarkdownKind.merge(base: nil, local: Data("a".utf8), remote: Data("a".utf8)) == Data("a".utf8))
        #expect(MarkdownKind.merge(base: nil, local: Data("a".utf8), remote: Data("b".utf8)) == nil)
    }
}

struct MarkdownFrontmatterTests {
    private func pin(_ md: String, _ pinned: Bool) throws -> String {
        String(decoding: try #require(MarkdownKind.setPinned(pinned, in: Data(md.utf8))), as: UTF8.self)
    }

    @Test func readsIconPinnedAndTags() {
        let md = """
        ---
        icon: "🌱"
        pinned: true # 首頁置頂
        tags: [生物, "plant"]
        ---
        # 光合作用
        #生物 內文
        """
        let entry = MarkdownKind.index(Data(md.utf8), fileName: "a.md")
        #expect(entry.icon == "🌱")
        #expect(entry.pinned)
        #expect(entry.tags == ["生物", "plant"])
        #expect(entry.title == "光合作用")
    }

    @Test func readsBlockListTagsAndCRLF() {
        let md = "---\r\ntags:\r\n  - a\r\n  - b\r\npinned: yes\r\n---\r\n# T\r\n"
        let entry = MarkdownKind.index(Data(md.utf8), fileName: "a.md")
        #expect(entry.tags == ["a", "b"])
        #expect(entry.pinned)
        #expect(!entry.plainText.contains("pinned"))
    }

    @Test func notPinnedWithoutFrontmatter() {
        let entry = MarkdownKind.index(Data("# T\n---\npinned: true\n---\n".utf8), fileName: "a.md")
        #expect(!entry.pinned)
        #expect(entry.icon == nil)
    }

    @Test func pinThenUnpinRestoresBytes() throws {
        for md in ["# 筆記\n\n內文\n", "沒有換行結尾", "---\ncreated: 2026-10-01\n---\n# A\n", "---\r\nicon: 🌱\r\n---\r\n# A\r\n", ""] {
            let pinned = try pin(md, true)
            #expect(MarkdownKind.index(Data(pinned.utf8), fileName: "a.md").pinned)
            #expect(try pin(pinned, false) == md)
        }
    }

    @Test func pinOnlyTouchesItsLine() throws {
        let md = "---\ntitle: x\npinned: false\ncover: a.png\n---\n# A\n"
        #expect(try pin(md, true) == "---\ntitle: x\npinned: true\ncover: a.png\n---\n# A\n")
        #expect(try pin("---\ntitle: x\n---\nbody", true) == "---\ntitle: x\npinned: true\n---\nbody")
        #expect(try pin("# A\n", true) == "---\npinned: true\n---\n# A\n")
    }

    @Test func emptyFrontmatterDoesNotCrash() {
        #expect(MarkdownKind.index(Data("---\n---\n# A".utf8), fileName: "a.md").title == "A")
        #expect(MarkdownKind.supportsPinning)
    }

    @Test func wordCountMixesCJKAndLatin() {
        #expect(MarkdownKind.wordCount("光合作用 is photo-synthesis！") == 4 + 3)
        let entry = MarkdownKind.index(Data(String(repeating: "字", count: 1240).utf8), fileName: "a.md")
        #expect(entry.summary == "1,240 字")
    }
}

struct MarkdownPreviewTests {
    @Test func titleAndCleanedLines() {
        let md = """
        ---
        pinned: true
        ---
        # 光合作用

        > [!tip] 重點
        - [ ] 讀 [[葉綠體|葉綠體筆記]] **第三章**
        ```swift
        let x = 1
        ```
        1. 第二步 ^c-a1b2
        """
        let preview = MarkdownPreview().makePreview(Data(md.utf8))
        #expect(preview.title == "光合作用")
        #expect(preview.lines == ["重點", "讀 葉綠體筆記 第三章", "第二步"])
    }

    @Test func withoutHeadingUsesLinesOnly() {
        let preview = MarkdownPreview().makePreview(Data((1...20).map { "第 \($0) 行" }.joined(separator: "\n").utf8))
        #expect(preview.title == nil)
        #expect(preview.lines.count == MarkdownPreview.maxLines)
    }
}

/// Bridge 的 `changed` 不能讓 JS 指定任意寫入路徑（security.md 不變條件 1、3）
struct MarkdownBridgeSecurityTests {
    @Test @MainActor func changedOnlyAcceptsLoadedSafePaths() {
        let loaded: Set<String> = ["筆記/a.md", "../evil.md", "/etc/passwd"]
        #expect(MarkdownEditor.acceptsChange(id: "筆記/a.md", loaded: loaded))
        #expect(!MarkdownEditor.acceptsChange(id: "筆記/b.md", loaded: loaded))
        #expect(!MarkdownEditor.acceptsChange(id: "../evil.md", loaded: loaded))
        #expect(!MarkdownEditor.acceptsChange(id: "/etc/passwd", loaded: loaded))
    }
}
