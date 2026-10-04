import Foundation
import Testing
@testable import Flashcards

/// 卡片寫在 `.md`、複習紀錄是各裝置同步來的 `.jsonl`：兩者都不可信
struct FlashcardParserFuzzTests {
    static let cards = [
        "Q::A ^abc123\n", "{{c1::克漏字}} 與 {{c2::另一個::提示}}\n", "正面 :: 背面\n多行\n::\n",
        "Q:::A\n", "{{c1::{{c2::巢狀}}}}\n", "^id ^id2\n",
    ].map { Data($0.utf8) }
    static let reviews = [
        #"{"id":1,"cid":"a","ease":3,"ivl":5,"lastIvl":1,"time":2000,"type":"review"}"#,
        #"{"id":2,"cid":"b","ease":0,"ivl":0,"lastIvl":0,"time":0,"type":"manual","op":"reset"}"#,
    ].map { Data($0.utf8) }

    @Test func cardSyntaxSurvivesAnyBytes() {
        let slow = Fuzz.run(seeds: Self.cards, rounds: 500) { data in
            let text = String(decoding: data, as: UTF8.self)
            _ = CardSyntax.parse(text)
            _ = CardSyntax.parseLines(text)
        }
        #expect(slow.isEmpty, "\(slow)")
    }

    @Test func pathologicalCardTextFinishesQuickly() {
        let inputs = [
            String(repeating: "{{c1::", count: 100_000), String(repeating: "::", count: 200_000),
            String(repeating: "^a", count: 200_000), String(repeating: "x", count: 5_000_000) + "::y",
            String(repeating: "Q::A\n", count: 5_000), // 線性成本；debug 建置每張卡約 0.15ms
        ]
        for text in inputs {
            let start = ContinuousClock.now
            _ = CardSyntax.parse(text)
            let seconds = Double((ContinuousClock.now - start).components.seconds)
            #expect(seconds < 5, "\(text.count) chars took \(seconds)s")
        }
    }

    @Test func reviewLineSurvivesAnyBytes() {
        let slow = Fuzz.run(seeds: Self.reviews, rounds: 600) { data in
            _ = ReviewEntry(line: Substring(String(decoding: data, as: UTF8.self)))
        }
        #expect(slow.isEmpty, "\(slow)")
    }
}
