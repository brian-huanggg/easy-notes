import Foundation
import Testing
@testable import EasyNotesCore

struct Diff3Tests {
    func merge(_ base: String, _ local: String, _ remote: String) -> String? {
        Diff3.merge(base: Data(base.utf8), local: Data(local.utf8), remote: Data(remote.utf8))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func linesRoundTrip() {
        for text in ["", "a", "a\n", "a\nb", "a\r\nb\r\n", "\n\n", "中文\n第二行"] {
            #expect(Diff3.lines(Data(text.utf8)).reduce(Data(), +) == Data(text.utf8))
        }
        #expect(Diff3.lines(Data("a\r\nb".utf8)).count == 2)
    }

    @Test func trivialCases() {
        #expect(merge("a\n", "a\n", "b\n") == "b\n")
        #expect(merge("a\n", "b\n", "a\n") == "b\n")
        #expect(merge("a\n", "c\n", "c\n") == "c\n")
    }

    @Test func separateParagraphsMerge() {
        let base = "# 標題\n\n第一段\n\n第二段\n\n第三段\n"
        let local = "# 標題\n\n第一段（iPad 改）\n\n第二段\n\n第三段\n"
        let remote = "# 標題\n\n第一段\n\n第二段\n\n第三段（Claude 改）\n"
        #expect(merge(base, local, remote) == "# 標題\n\n第一段（iPad 改）\n\n第二段\n\n第三段（Claude 改）\n")
    }

    @Test func sameLineEditedBothSidesConflicts() {
        #expect(merge("a\nb\nc\n", "a\nB1\nc\n", "a\nB2\nc\n") == nil)
    }

    @Test func identicalChangeOnBothSidesIsNotAConflict() {
        #expect(merge("a\nb\nc\nd\n", "a\nX\nc\nd\n", "a\nX\nc\nD\n") == "a\nX\nc\nD\n")
    }

    @Test func insertionsAndDeletions() {
        let base = "1\n2\n3\n4\n5\n"
        // 本地在開頭插入、遠端刪掉第 4 行
        #expect(merge(base, "0\n1\n2\n3\n4\n5\n", "1\n2\n3\n5\n") == "0\n1\n2\n3\n5\n")
        // 兩邊在檔尾各自附加不同內容 → 衝突
        #expect(merge(base, base + "L\n", base + "R\n") == nil)
        // 兩邊在不同位置附加
        #expect(merge(base, "1\nL\n2\n3\n4\n5\n", "1\n2\n3\n4\n5\nR\n") == "1\nL\n2\n3\n4\n5\nR\n")
    }

    @Test func crlfIsPreserved() {
        let base = "a\r\nb\r\nc\r\n"
        #expect(merge(base, "A\r\nb\r\nc\r\n", "a\r\nb\r\nC\r\n") == "A\r\nb\r\nC\r\n")
    }

    @Test func missingTrailingNewline() {
        let base = "a\nb\nc"
        #expect(merge(base, "A\nb\nc", "a\nb\nC") == "A\nb\nC")
        // 一邊在檔尾附加（最後一行多了 \n），另一邊改開頭
        #expect(merge(base, "a\nb\nc\nd", "X\nb\nc") == "X\nb\nc\nd")
    }

    @Test func frontmatterAndBodyMerge() {
        let base = "---\ntags: [a]\n---\n\n# 筆記\n\n內容\n"
        let local = "---\ntags: [a, b]\n---\n\n# 筆記\n\n內容\n"
        let remote = "---\ntags: [a]\n---\n\n# 筆記\n\n內容\n\n新段落\n"
        #expect(merge(base, local, remote) == "---\ntags: [a, b]\n---\n\n# 筆記\n\n內容\n\n新段落\n")
    }

    @Test func resolveSettlesConflictingBlocks() {
        let base = ["a", "b", "c"]
        // 預設沒有 resolve：同一行兩邊改成不同值 → 衝突
        #expect(Diff3.merge(base: base, local: ["a", "B1", "c"], remote: ["a", "B2", "c"]) == nil)
        // resolve 拿到的是衝突區塊本身，回傳值取代該區塊
        var seen: [[String]] = []
        let merged = Diff3.merge(base: base, local: ["a", "B1", "c"], remote: ["a", "B2", "c"]) { o, l, r in
            seen = [Array(o), Array(l), Array(r)]
            return [l.first! + "+" + r.first!]
        }
        #expect(merged == ["a", "B1+B2", "c"])
        #expect(seen == [["b"], ["B1"], ["B2"]])
        // resolve 回傳 nil 仍是衝突；不衝突的區塊不經過 resolve
        #expect(Diff3.merge(base: base, local: ["a", "B1", "c"], remote: ["a", "B2", "c"]) { _, _, _ in nil } == nil)
        #expect(Diff3.merge(base: base, local: ["A", "b", "c"], remote: ["a", "b", "C"]) { _, _, _ in Issue.record(); return nil }
                == ["A", "b", "C"])
    }

    @Test func emptyBase() {
        #expect(merge("", "a\n", "a\n") == "a\n")
        #expect(merge("", "a\n", "b\n") == nil)
    }
}
