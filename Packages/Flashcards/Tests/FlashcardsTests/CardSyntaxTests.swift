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
