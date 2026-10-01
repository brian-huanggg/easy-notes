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
