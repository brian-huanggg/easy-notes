import Foundation
import Testing
@testable import Flashcards

/// 參考向量（`scripts/fsrs-vectors.py` 由 fsrs-rs 與 py-fsrs 產生）
struct Vectors: Decodable {
    struct Memory: Decodable { var stability: Double; var difficulty: Double }
    struct Review: Decodable { var rating: Int; var days: Int }
    struct MemoryCase: Decodable { var reviews: [Review]; var states: [Memory] }
    struct Next: Decodable { var stability: Double; var difficulty: Double; var interval: Double }
    struct NextCase: Decodable { var memory: Memory; var days: Int; var retention: Double; var next: [Next] }
    struct Step: Decodable {
        var rating: Int, minutes: Int, state: String, step: Int?, dueSeconds: Int
        /// 複習卡套上 Anki 的 Hard ≤ Good < Easy 限制後的間隔
        var ankiDays: Int?
        var stability: Double, difficulty: Double
    }
    struct Params: Decodable {
        var name: String
        var w: [Double]
        var memory: [MemoryCase]
        var next: [NextCase]
        var scheduler: [[Step]]
    }
    var start: String
    var params: [Params]

    static let shared: Vectors = {
        let url = Bundle.module.url(forResource: "fsrs-vectors", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
}

/// fsrs-rs 以 Float32 計算
func close(_ a: Double?, _ b: Double, _ tolerance: Double = 2e-3) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance * max(1, abs(b))
}

struct FSRSVectorTests {
    static let utc = DayClock(timeZone: TimeZone(identifier: "UTC")!, rolloverHour: 0)
    static let start = ISO8601DateFormatter().date(from: Vectors.shared.start)!

    func scheduler(_ params: Vectors.Params, retention: Double = 0.9, relearningSteps: [TimeInterval] = [600]) -> Scheduler {
        var preset = Preset()
        preset.w = params.w
        preset.desiredRetention = retention
        preset.relearningSteps = relearningSteps
        return Scheduler(preset: preset, clock: Self.utc, fuzz: false)
    }

    /// 重播只用紀錄的評分與時間，記憶狀態要與 fsrs-rs 相同（含同一天內的多次複習）
    @Test(arguments: Vectors.shared.params.map(\.name))
    func memoryStatesMatchFSRSrs(_ name: String) throws {
        let params = Vectors.shared.params.first { $0.name == name }!
        let scheduler = scheduler(params)
        for (n, item) in params.memory.enumerated() {
            var card = CardSchedule()
            var date = Self.start
            for (i, review) in item.reviews.enumerated() {
                date = date.addingTimeInterval(Double(review.days) * 86_400 + 60) // 同一天的複習相隔一分鐘
                // ivl 只影響到期日與狀態，記憶狀態只看評分與天數
                let entry = ReviewEntry(id: date.millis, cid: "c", ease: review.rating, ivl: review.rating == 1 ? -60 : 1,
                                        lastIvl: card.lastIvl, time: 0, type: .learning)
                card = scheduler.apply(entry, to: card)
                let expected = item.states[i]
                #expect(close(card.stability, expected.stability), "\(name) case \(n) review \(i): S \(card.stability!) ≠ \(expected.stability)")
                #expect(close(card.difficulty, expected.difficulty), "\(name) case \(n) review \(i): D \(card.difficulty!) ≠ \(expected.difficulty)")
            }
        }
    }

    /// 複習卡的四個按鈕：記憶狀態與 fsrs-rs 相同；間隔 = 四捨五入後再套上 Hard ≤ Good < Easy
    @Test(arguments: Vectors.shared.params.map(\.name))
    func reviewIntervalsMatchFSRSrs(_ name: String) throws {
        let params = Vectors.shared.params.first { $0.name == name }!
        for item in params.next {
            let now = Self.start.addingTimeInterval(400 * 86_400)
            var card = CardSchedule()
            card.phase = .review
            card.stability = item.memory.stability
            card.difficulty = item.memory.difficulty
            card.lastReview = now.addingTimeInterval(-Double(item.days) * 86_400)
            card.reps = 3
            let preview = scheduler(params, retention: item.retention).preview(card, cid: "c", now: now)
            let noRelearning = scheduler(params, retention: item.retention, relearningSteps: [])
                .preview(card, cid: "c", now: now)
            for grade in Grade.allCases {
                let expected = item.next[grade.rawValue - 1]
                let next = scheduler(params, retention: item.retention).apply(preview[grade]!, to: card)
                #expect(close(next.stability, expected.stability), "\(name) \(grade) S \(next.stability!) ≠ \(expected.stability)")
                #expect(close(next.difficulty, expected.difficulty), "\(name) \(grade) D \(next.difficulty!) ≠ \(expected.difficulty)")
            }
            let rounded = item.next.map { max(1, Int($0.interval.rounded())) }
            let good = rounded[2]
            #expect(preview[.again]!.ivl == -600)
            #expect(noRelearning[.again]!.ivl == rounded[0])
            #expect(preview[.hard]!.ivl == min(rounded[1], good))
            #expect(preview[.good]!.ivl == max(good, preview[.hard]!.ivl + 1))
            #expect(preview[.easy]!.ivl == max(rounded[3], preview[.good]!.ivl + 1))
        }
    }

    /// 完整排程（learning / relearning steps、畢業、到期時間）與 py-fsrs 相同；複習卡的間隔另套上 Anki 的限制
    @Test(arguments: Vectors.shared.params.map(\.name))
    func schedulingMatchesPyFSRS(_ name: String) throws {
        let params = Vectors.shared.params.first { $0.name == name }!
        let scheduler = scheduler(params)
        for (n, steps) in params.scheduler.enumerated() {
            var card = CardSchedule()
            for (i, step) in steps.enumerated() {
                let now = Self.start.addingTimeInterval(Double(step.minutes) * 60)
                let entry = scheduler.preview(card, cid: "c", now: now)[Grade(rawValue: step.rating)!]!
                card = scheduler.apply(entry, to: card)
                let label = "\(name) case \(n) review \(i)"
                #expect(card.phase.rawValue == step.state, "\(label): \(card.phase) ≠ \(step.state)")
                if card.phase != .review {
                    #expect(card.step == step.step, "\(label): step \(card.step) ≠ \(step.step ?? -1)")
                    #expect(-entry.ivl == step.dueSeconds, "\(label): \(-entry.ivl)s ≠ \(step.dueSeconds)s")
                } else {
                    let days = step.ankiDays ?? step.dueSeconds / 86_400
                    #expect(entry.ivl == days, "\(label): \(entry.ivl)d ≠ \(days)d")
                }
                #expect(close(card.stability, step.stability), "\(label): S \(card.stability!) ≠ \(step.stability)")
                #expect(close(card.difficulty, step.difficulty), "\(label): D \(card.difficulty!) ≠ \(step.difficulty)")
            }
        }
    }
}
