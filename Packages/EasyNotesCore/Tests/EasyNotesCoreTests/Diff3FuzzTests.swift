import Foundation
import Testing
@testable import EasyNotesCore

/// Sync merge consumes remote content: it must not crash and must not hang on pathological input
struct Diff3FuzzTests {
    @Test func mergeSurvivesAnyBytes() {
        let seeds = ["a\nb\nc\n", "一\r\n二\r\n三", "\n\n\n", "x"].map { Data($0.utf8) }
        var n = 0
        let slow = Fuzz.run(seeds: seeds, rounds: 500) { data in
            n += 1
            _ = Diff3.merge(base: seeds[n % seeds.count], local: data, remote: seeds[(n + 1) % seeds.count])
            _ = Diff3.merge(base: data, local: seeds[n % seeds.count], remote: data.reversed().reduce(into: Data()) { $0.append($1) })
        }
        #expect(slow.isEmpty, "\(slow)")
    }

    @Test func largeUnrelatedFilesFinishQuickly() {
        func lines(_ prefix: String, _ n: Int) -> Data { Data((0..<n).map { "\(prefix)\($0)\n" }.joined().utf8) }
        let cases: [(Data, Data, Data)] = [
            (lines("a", 20_000), lines("b", 20_000), lines("c", 20_000)),       // Completely different
            (Data(String(repeating: "x\n", count: 50_000).utf8), lines("y", 100), Data(String(repeating: "x\n", count: 49_000).utf8)),
            (lines("a", 200_000), lines("a", 200_001), lines("a", 199_999)),   // A big file with a small change
        ]
        for (i, (base, local, remote)) in cases.enumerated() {
            let start = ContinuousClock.now
            let merged = Diff3.merge(base: base, local: local, remote: remote)
            let seconds = Double((ContinuousClock.now - start).components.seconds)
            #expect(seconds < 10, "case \(i) took \(seconds)s")
            if i == 0 { #expect(merged == nil) } // Above the cost cap: treated as a conflict, not merged
        }
    }

    /// Ordinary use is unaffected: a big file with a small change, or pasting many new lines, still merges
    @Test func ordinaryLargeEditsStillMerge() {
        let base = Data((0..<50_000).map { "line \($0)\n" }.joined().utf8)
        var l = (0..<50_000).map { "line \($0)\n" }; l[10] = "LOCAL\n"
        var r = (0..<50_000).map { "line \($0)\n" }; r[40_000] = "REMOTE\n"
        r.insert(contentsOf: (0..<2_000).map { "pasted \($0)\n" }, at: 20_000)
        let merged = Diff3.merge(base: base, local: Data(l.joined().utf8), remote: Data(r.joined().utf8))
        #expect(merged != nil)
        #expect(merged.map { String(decoding: $0, as: UTF8.self).contains("LOCAL") && String(decoding: $0, as: UTF8.self).contains("REMOTE") } == true)
    }
}
