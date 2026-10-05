import Testing
@testable import Flashcards

struct CardMarkupTests {
    typealias Block = CardMarkup.Block

    @Test func plainText() {
        #expect(CardMarkup.blocks("光合作用") == [.paragraph([.text("光合作用")])])
    }

    @Test func inlineMarkdown() {
        #expect(CardMarkup.blocks("**粗** *斜* ~~刪~~ ==螢光== `a*b*`") == [.paragraph([
            .text("粗", .bold), .text(" "), .text("斜", .italic), .text(" "), .text("刪", .strike), .text(" "),
            .text("螢光", .highlight), .text(" "), .text("a*b*", .code),
        ])])
        #expect(CardMarkup.blocks("[[頁面|別名]]、[網站](https://example.com)") == [.paragraph([
            .text("別名、"), .text("網站", link: "https://example.com"),
        ])])
    }

    @Test func inlineMath() {
        #expect(CardMarkup.blocks("能量 $E=mc^2$ 守恆") == [.paragraph([.text("能量 "), .math("E=mc^2"), .text(" 守恆")])])
        // 公式內的 Markdown 不轉換；公式外的 Markdown 可以包住公式
        #expect(CardMarkup.blocks("**$a*b*c$**") == [.paragraph([.math("a*b*c", .bold)])])
        #expect(CardMarkup.blocks("\\$5 和 $10") == [.paragraph([.text("$5 和 $10")])])
    }

    @Test func displayMathIsItsOwnBlock() {
        #expect(CardMarkup.blocks("積分 $$\\int_0^1 x\\,dx$$ 等於 1/2") == [
            .paragraph([.text("積分")]), .math("\\int_0^1 x\\,dx"), .paragraph([.text("等於 1/2")]),
        ])
        #expect(CardMarkup.blocks("$$x^2$$") == [.math("x^2")])
    }

    @Test func clozeSegments() {
        let note = CardNote(id: "c-a1b2c3", type: .cloze, line: 0, front: "**{{$\\frac{a}{b}$}}** 是{{分數}}", back: "",
                            clozes: ["$\\frac{a}{b}$", "分數"])
        let cards = StudyCard.cards(path: "數學.md", note: note)
        // 正面：挖空處標成克漏字，外面的粗體保留
        #expect(CardMarkup.blocks(cards[0].front) == [.paragraph([
            .text(StudyCard.clozeBlank, [.bold, .cloze]), .text(" 是分數"),
        ])])
        // 背面：答案中的公式也標成克漏字
        #expect(CardMarkup.blocks(cards[0].back) == [.paragraph([.math("\\frac{a}{b}", [.bold, .cloze]), .text(" 是分數")])])
        #expect(CardMarkup.blocks(cards[1].back) == [.paragraph([
            .math("\\frac{a}{b}", .bold), .text(" 是"), .text("分數", .cloze),
        ])])
    }
}
