import EasyNotesCore
import Foundation
import Testing
@testable import Flashcards

struct CardSyntaxTests {
    @Test func threeSyntaxes() {
        let notes = CardSyntax.parse("""
            # 生物

            光合作用發生在 :: 葉綠體 ^c-a1b2c3
            - 中文 ;; Chinese
            {{粒線體}}是{{細胞的發電廠}} ^c-g7h8i9
            一般段落，不是卡片。
            """)
        #expect(notes == [
            CardNote(id: "c-a1b2c3", type: .forward, line: 2, front: "光合作用發生在", back: "葉綠體"),
            CardNote(id: nil, type: .bidirectional, line: 3, front: "中文", back: "Chinese"),
            CardNote(id: "c-g7h8i9", type: .cloze, line: 4, front: "{{粒線體}}是{{細胞的發電廠}}", back: "",
                     clozes: ["粒線體", "細胞的發電廠"]),
        ])
        #expect(notes[0].cardIDs == ["c-a1b2c3"])
        #expect(notes[2].cardIDs == ["c-g7h8i9:1", "c-g7h8i9:2"])
        #expect(CardNote(id: "c-x", type: .bidirectional, line: 0, front: "a", back: "b").cardIDs == ["c-x", "c-x:r"])
    }

    @Test func linePrefixesAreNotPartOfFront() {
        let fronts = CardSyntax.parse("""
            - [ ] 待辦 :: 一
            1. 編號 :: 二
            ## 標題 :: 三
            > 引言 :: 四
                - 縮排清單 :: 五
            """).map(\.front)
        #expect(fronts == ["待辦", "編號", "標題", "引言", "縮排清單"])
    }

    @Test func codeAndFrontmatterAreIgnored() {
        let notes = CardSyntax.parse("""
            ---
            title: 問 :: 答
            ---
            ```swift
            let a = b :: c
            ```
            ~~~
            {{不是卡片}}
            ~~~
            `x :: y` 只是程式碼
            `{{template}}` 也不是
            真的 :: 卡片
            """)
        #expect(notes.map(\.front) == ["真的"])
        #expect(notes.first?.line == 11)
    }

    @Test func separatorNeedsSpaces() {
        #expect(CardSyntax.parse("std::vector 和 a;;b 都不是卡片\nhttp://example.com").isEmpty)
        #expect(CardSyntax.parse("問 :: ").isEmpty)
        #expect(CardSyntax.parse(":: 答").isEmpty)
        #expect(CardSyntax.parse("空的 {{ }} 克漏字").isEmpty)
    }

    /// 公式與行內程式碼一樣受保護（web/test/cardSyntax.test.ts 有相同的案例）
    @Test func mathIsProtected() {
        #expect(CardSyntax.parse("$a :: b$ 不是卡片").isEmpty)
        #expect(CardSyntax.parse("$\\frac{{a}}{b}$ 不是克漏字").isEmpty)
        let fraction = CardSyntax.parse("{{$\\frac{a}{b}$}} 是分數").first
        #expect(fraction?.type == .cloze)
        #expect(fraction?.clozes == ["$\\frac{a}{b}$"])
        let energy = CardSyntax.parse("$E=mc^2$ :: 質能等價").first
        #expect(energy?.front == "$E=mc^2$")
        #expect(energy?.back == "質能等價")
    }

    @Test func mathSpans() {
        func spans(_ text: String) -> [String] {
            CardSyntax.mathSpans(in: text[...], code: CardSyntax.codeSpans(in: text[...]))
                .map { ($0.display ? "D:" : "I:") + text[$0.range] }
        }
        #expect(spans("能量 $E=mc^2$ 與 $$\\int_0^1 x\\,dx$$") == ["I:$E=mc^2$", "D:$$\\int_0^1 x\\,dx$$"])
        // 金額不是公式
        #expect(spans("$5 和 $10").isEmpty)
        #expect(spans("花了 $5, 剩 $10.").isEmpty)
        #expect(spans("$ x$ 與 $x $").isEmpty)
        #expect(spans("$x$5").isEmpty)
        #expect(spans("$$ $$").isEmpty)
        // 跳脫與程式碼
        #expect(spans("\\$x$").isEmpty)
        #expect(spans("$a\\$b$") == ["I:$a\\$b$"])
        #expect(spans("`$x$` 與 $y$") == ["I:$y$"])
        #expect(spans("$a `b$`").isEmpty)
    }

    @Test func clozeRulesMatchPreviousRegex() {
        func answers(_ text: String) -> [String] { CardSyntax.clozeMatches(in: text[...]).map { String($0.answer) } }
        #expect(answers("{{}}").isEmpty)
        #expect(answers("{{{a}}") == ["a"])
        #expect(answers("{{a}}}") == ["a"])
        #expect(answers("{{a}b}}").isEmpty)
        #expect(answers("`{{b}}` 與 {{c}}") == ["c"])
        #expect(answers("{{a `b`}}") == ["a `b`"])
        #expect(answers("{{`x }} y`}}") == ["`x }} y`"])
        #expect(answers("{{a `b}} c`").isEmpty)
        #expect(answers("$x$ 與 {{y}}") == ["y"])
    }

    @Test func firstSeparatorWins() {
        let note = CardSyntax.parse("a ;; b :: c").first
        #expect(note?.type == .bidirectional)
        #expect(note?.front == "a")
        #expect(note?.back == "b :: c")
    }

    @Test func existingObsidianBlockIDIsReused() {
        #expect(CardSyntax.parse("問 :: 答 ^my-block").first?.id == "my-block")
    }

    @Test func crlfLines() {
        let notes = CardSyntax.parse("問 :: 答 ^c-aaaaaa\r\n第二 :: 張\r\n")
        #expect(notes.map(\.id) == ["c-aaaaaa", nil])
        #expect(notes.map(\.back) == ["答", "張"])
    }
}

struct MultilineCardTests {
    @Test func childrenAreTheBack() {
        let notes = CardSyntax.parse("""
            - 請說明 **SDT** 的三大要素 :: ^c-a1b2c3
              ![[sdt.png]]

              - Competence：能力
              - Autonomy：自主
            不是子行
            """)
        #expect(notes == [CardNote(id: "c-a1b2c3", type: .forward, line: 0, endLine: 4, front: "請說明 **SDT** 的三大要素",
                                   back: "![[sdt.png]]\n\n- Competence：能力\n- Autonomy：自主")])
    }

    @Test func dividerSplitsMultilineFront() {
        let note = CardSyntax.parse("""
            - To find all **running processes** ;;
              - The process containing "python"
              ::
              `ps aux | grep python`
            """).first
        #expect(note?.type == .bidirectional)
        #expect(note?.front == "To find all **running processes**\n- The process containing \"python\"")
        #expect(note?.back == "`ps aux | grep python`")
        #expect(note?.cardIDs.count == 0)
    }

    @Test func clozeInChildrenWithBackExtra() {
        let note = CardSyntax.parse("""
            - Erikson 的發展理論 :: ^c-g7h8i9
              - 嬰兒期：{{信任對不信任}}
              - 成年早期：{{ 親密對孤立 }} ^c-zzzzzz

              ::
              補充 {{不算}}
            """).first
        #expect(note?.type == .cloze)
        #expect(note?.front == "Erikson 的發展理論\n- 嬰兒期：{{信任對不信任}}\n- 成年早期：{{ 親密對孤立 }}")
        #expect(note?.back == "補充 {{不算}}")
        #expect(note?.clozes == ["信任對不信任", "親密對孤立"])
        #expect(note?.cardIDs == ["c-g7h8i9:1", "c-g7h8i9:2"])
        #expect(note?.endLine == 5)
    }

    @Test func clozeWithoutDividerUsesAllChildren() {
        let note = CardSyntax.parse("- 指令 {{I}} :: \n  - 行尾：{{A}}").first
        #expect(note?.type == .cloze)
        #expect(note?.clozes == ["I", "A"])
        #expect(note?.back == "")
    }

    @Test func singleLineNotesKeepTheirChildren() {
        let notes = CardSyntax.parse("""
            - 動物 :: animal
              - 犬 :: いぬ
            - {{粒線體}}是發電廠
              - 補充說明
            """)
        #expect(notes.map(\.front) == ["動物", "犬", "{{粒線體}}是發電廠"])
        #expect(notes.map(\.endLine) == [0, 1, 2])
    }

    @Test func childrenAreContentNotCards() {
        let notes = CardSyntax.parse("""
            - 父 ::
              - 子 :: 卡片 ^c-aaaaaa
            - 下一張 :: 卡
            """)
        #expect(notes.map(\.front) == ["父", "下一張"])
        #expect(notes[0].back == "- 子 :: 卡片")
        #expect(notes[0].id == nil)
    }

    @Test func extentFollowsListIndentation() {
        let notes = CardSyntax.parse("""
            1. 編號 ::
               答案一
              不足三欄
            \t- tab 首行 ::
            \t\t子行

            後面
            """)
        #expect(notes.map(\.back) == ["答案一", "子行"])
        #expect(notes.map(\.endLine) == [1, 4])
    }

    @Test func notMultiline() {
        // 首行不是清單、引言中的清單、沒有子行、分隔符號在程式碼或公式中
        #expect(CardSyntax.parse("段落 ::\n  縮排").isEmpty)
        #expect(CardSyntax.parse("> - 引言 ::\n>   子行").isEmpty)
        #expect(CardSyntax.parse("- 沒有子行 ::\n- 下一個").isEmpty)
        #expect(CardSyntax.parse("- `a ::`\n  子行").isEmpty)
        #expect(CardSyntax.parse("- $a ::$\n  子行").isEmpty)
        #expect(CardSyntax.parse("- ::\n  子行").isEmpty)
        // 有分界行但背面是空的
        #expect(CardSyntax.parse("- 問 ::\n  前\n  ::").isEmpty)
        #expect(CardSyntax.parse("- 空的 ::\n  {{ }}").isEmpty)
    }

    @Test func fencedCodeInsideChildren() {
        let note = CardSyntax.parse("""
            - 查版本 ::
              ```
              ::
              {{not}} ^c-keep11
              ```
              結尾
            """).first
        #expect(note?.type == .forward)
        #expect(note?.back == "```\n::\n{{not}} ^c-keep11\n```\n結尾")
        // 沒有關閉的程式碼區塊不會延伸到 note 之外
        let notes = CardSyntax.parse("- 問 ::\n  ```\n  code\n- 下一張 :: 卡")
        #expect(notes.map(\.front) == ["問", "下一張"])
    }

    @Test func clozeSegmentsAcrossLines() {
        let segments = CardSyntax.clozeSegments("a {{b}}\n`c\n{{d}}` $e\n$ {{f}}\n```\n{{g}}\n```")
        #expect(segments.filter { $0.cloze != nil }.map(\.text) == ["b", "d", "f"])
        #expect(segments.map(\.text).joined() == "a b\n`c\nd` $e\n$ f\n```\n{{g}}\n```")
    }

    @Test func idGoesOnTheHeadLine() throws {
        let text = "- 問 ::\n  答一\n  答二\n"
        let filled = try #require(CardIDs.fill(text, path: "a.md"))
        let lines = filled.components(separatedBy: "\n")
        let id = try #require(CardSyntax.parse(filled).first?.id)
        #expect(lines[0] == "- 問 :: ^\(id)")
        #expect(lines[1...] == ["  答一", "  答二", ""])
        // id 只看首行：改子行不影響
        #expect(CardIDs.fill("- 問 ::\n  別的答案\n", path: "a.md")?.hasPrefix(lines[0]) == true)
    }

    @Test func codableDefaultsEndLine() throws {
        let old = #"{"back":"b","clozes":[],"front":"a","line":3,"type":"forward"}"#
        let note = try JSONDecoder().decode(CardNote.self, from: Data(old.utf8))
        #expect(note.endLine == 3)
    }
}

struct CardIDsTests {
    @Test func missingIDsAreFilled() throws {
        let text = "# 單字\n\n- 蘋果 ;; apple\n香蕉 :: banana  \n不是卡片\n"
        let filled = try #require(CardIDs.fill(text, path: "英文/水果.md"))
        let notes = CardSyntax.parse(filled)
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0.id?.wholeMatch(of: /c-[0-9a-z]{6}/) != nil })
        // 只多了 id，其他內容（含行尾兩個空白）不變
        let lines = filled.components(separatedBy: "\n")
        #expect(lines[2] == "- 蘋果 ;; apple ^\(notes[0].id!)")
        #expect(lines[3] == "香蕉 :: banana ^\(notes[1].id!)  ")
        #expect(lines[4] == "不是卡片")
        #expect(filled.hasSuffix("\n"))
        // 已經都有 id：不需要修改
        #expect(CardIDs.fill(filled, path: "英文/水果.md") == nil)
    }

    @Test func idsAreDeterministic() {
        let text = "問 :: 答\n"
        let a = CardIDs.fill(text, path: "a.md")
        #expect(a == CardIDs.fill(text, path: "a.md"))
        #expect(a != CardIDs.fill(text, path: "b.md"))
    }

    @Test func editingTextKeepsID() throws {
        let filled = try #require(CardIDs.fill("問 :: 答\n", path: "a.md"))
        let id = try #require(CardSyntax.parse(filled).first?.id)
        let edited = filled.replacingOccurrences(of: "答", with: "改過的答案")
        #expect(CardIDs.fill(edited, path: "a.md") == nil)
        #expect(CardSyntax.parse(edited).first?.id == id)
    }

    @Test func duplicateInFileOnlyChangesLaterLine() throws {
        let text = "第一 :: 張 ^c-aaaaaa\n複製 :: 張 ^c-aaaaaa\n"
        let filled = try #require(CardIDs.fill(text, path: "a.md"))
        let ids = CardSyntax.parse(filled).map(\.id)
        #expect(ids[0] == "c-aaaaaa")
        #expect(ids[1] != "c-aaaaaa")
        #expect(filled.hasPrefix("第一 :: 張 ^c-aaaaaa\n複製 :: 張 ^c-"))
    }

    @Test func identicalLinesGetDifferentIDs() throws {
        let filled = try #require(CardIDs.fill("同 :: 一\n同 :: 一\n", path: "a.md"))
        let ids = CardSyntax.parse(filled).compactMap(\.id)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    @Test func idTakenByAnotherFileIsReplaced() throws {
        let filled = try #require(CardIDs.fill("貼上 :: 的卡片 ^c-aaaaaa\n", path: "b.md") { $0 == "c-aaaaaa" })
        #expect(CardSyntax.parse(filled).first?.id != "c-aaaaaa")
    }

    @Test func generatedIDAvoidsIDsLaterInFile() throws {
        let path = "a.md"
        let wouldBe = CardIDs.make(path: path, content: "新 :: 卡", attempt: 0)
        let filled = try #require(CardIDs.fill("新 :: 卡\n舊 :: 卡 ^\(wouldBe)\n", path: path))
        let ids = CardSyntax.parse(filled).compactMap(\.id)
        #expect(ids[1] == wouldBe)
        #expect(ids[0] != wouldBe)
    }

    @Test func crlfIsPreserved() throws {
        let filled = try #require(CardIDs.fill("問 :: 答\r\n其他\r\n", path: "a.md"))
        #expect(filled.wholeMatch(of: /問 :: 答 \^c-[0-9a-z]{6}\r\n其他\r\n/) != nil)
    }

    /// 兩台裝置替同一行補 id：結果相同，diff3 視為同一個修改（另一處的編輯照常合併）
    @Test func twoDevicesMergeCleanly() throws {
        let text = "# 筆記\n問 :: 答\n\n結尾\n"
        let filled = try #require(CardIDs.fill(text, path: "筆記.md"))
        let mac = Data((filled + "Mac 加的一行\n").utf8)
        let ipad = Data(try #require(CardIDs.fill(text, path: "筆記.md")).utf8)
        let merged = try #require(Diff3.merge(base: Data(text.utf8), local: mac, remote: ipad))
        #expect(merged == mac)
    }
}
