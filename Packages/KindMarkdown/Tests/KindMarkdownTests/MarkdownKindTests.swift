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
