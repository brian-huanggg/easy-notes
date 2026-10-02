import Foundation
import FSRS

public enum CardPhase: String, Codable, Sendable {
    case new, learning, review, relearning
}

/// 卡片的排程狀態。不另存：由複習紀錄重播得出（`Scheduler.replay`）。
public struct CardSchedule: Equatable, Sendable {
    public var phase: CardPhase = .new
    /// learning / relearning steps 的第幾步（從 0 起算）
    public var step = 0
    /// 新卡為 nil
    public var due: Date?
    public var stability: Double?
    public var difficulty: Double?
    public var reps = 0
    public var lapses = 0
    public var lastReview: Date?
    /// 上一次的 `ivl`（寫進下一筆紀錄的 `lastIvl`）
    public var lastIvl = 0
    public var suspended = false

    public init() {}
}

/// 牌組設定（多個牌組共用）。預設值與 Anki 相同。
/// 存檔時每個欄位各自一筆（見 `SRSSettings`），所以新增欄位不需要遷移，沒寫過的欄位就是預設值。
public struct Preset: Codable, Equatable, Sendable {
    public enum LeechAction: String, Codable, Sendable, CaseIterable {
        /// 只加上虛擬標籤 `leech`（不改 md）
        case tag
        case suspend
    }

    public enum NewOrder: String, Codable, Sendable, CaseIterable {
        /// 依路徑、行號
        case file
        /// 以「卡片 id + 日期」的 hash 排序，同一天內穩定
        case random
    }

    public enum ReviewOrder: String, Codable, Sendable, CaseIterable {
        case due
        /// 可回想率低的在前
        case retrievability
    }

    public var name = "預設"
    /// 每日上限（母牌組的上限涵蓋子牌組）
    public var newPerDay = 20
    public var reviewsPerDay = 200
    /// 秒
    public var learningSteps: [TimeInterval] = [60, 600]
    public var relearningSteps: [TimeInterval] = [600]
    public var desiredRetention = 0.9
    /// 天
    public var maximumInterval = 36_500
    /// FSRS-6 的 21 個參數
    public var w: [Double] = FSRSDefaults.defaultWv6
    public var leechThreshold = 8
    public var leechAction = LeechAction.tag
    public var newOrder = NewOrder.file
    public var reviewOrder = ReviewOrder.due
    /// 同一行今天已複習過其他卡片時，當天不出現
    public var buryNew = false
    public var buryReviews = false

    public init() {}

    /// 排程結果只受這些欄位影響（改名、上限不必重播）
    var schedulingFields: [Double] {
        learningSteps + [-1] + relearningSteps + [-1, desiredRetention, Double(maximumInterval)] + w
    }
}

/// 排程與重播。FSRS 的計算（記憶狀態、複習間隔、fuzz）交給 swift-fsrs；
/// learning / relearning steps 依 Anki 的規則在這裡處理（swift-fsrs 的 Hard 在第二步以後與 Anki 不同）。
///
/// 作答與重播走同一條路徑：`preview` 算出每個按鈕的紀錄，作答時把選到的那筆交給 `apply`，
/// 與日後在其他裝置重播得到的狀態相同。
public struct Scheduler: Sendable {
    public let preset: Preset
    public let clock: DayClock
    private let fsrs: FSRS
    /// 重播只需要記憶狀態，不需要 fuzz（PRNG 以字串 seed 初始化，很慢）
    private let memoryFSRS: FSRS

    /// - Parameter fuzz: Anki 的 fuzz 不能關；只有測試時關掉，以便與參考向量比對
    public init(preset: Preset = Preset(), clock: DayClock = DayClock(), fuzz: Bool = true) {
        self.preset = preset
        self.clock = clock
        // steps 由這裡處理，swift-fsrs 只算記憶狀態與間隔：steps 留空，每個評分都直接給出以天計的間隔
        func make(fuzz: Bool) -> FSRS {
            FSRS(parameters: FSRSParameters(
                requestRetention: preset.desiredRetention, maximumInterval: Double(preset.maximumInterval),
                w: preset.w, enableFuzz: fuzz, enableShortTerm: true, learningSteps: [], relearningSteps: []))
        }
        fsrs = make(fuzz: fuzz)
        memoryFSRS = make(fuzz: false)
    }

    // MARK: 作答

    /// 四個按鈕各自的紀錄（`ivl` 即下次間隔）；作答時把選到的那筆（填上 `time`）寫進紀錄並交給 `apply`
    public func preview(_ card: CardSchedule, cid: String, now: Date) -> [Grade: ReviewEntry] {
        let results = fsrsPreview(card, at: now)
        var entries: [Grade: ReviewEntry] = [:]
        for grade in Grade.allCases {
            let ivl: Int
            switch card.phase {
            case .new:
                ivl = stepDelay(preset.learningSteps, step: 0, grade: grade) ?? results[grade]?.days ?? 1
            case .learning:
                ivl = stepDelay(preset.learningSteps, step: card.step, grade: grade) ?? results[grade]?.days ?? 1
            case .relearning:
                ivl = stepDelay(preset.relearningSteps, step: card.step, grade: grade) ?? results[grade]?.days ?? 1
            case .review:
                if grade == .again, let first = preset.relearningSteps.first {
                    ivl = -Self.seconds(first)
                } else {
                    ivl = results[grade]?.days ?? 1
                }
            }
            entries[grade] = ReviewEntry(id: now.millis, cid: cid, ease: grade.rawValue, ivl: ivl,
                                         lastIvl: card.lastIvl, time: 0, type: kind(of: card.phase))
        }
        return entries
    }

    /// Anki 的規則：Again 回到第一步；Hard 在第一步時取前兩步的平均（只有一步時 ×1.5，最多多一天），
    /// 之後重複目前這一步；Good 進到下一步，沒有下一步就畢業；Easy 直接畢業。
    /// 回傳負數秒，nil = 畢業（改用 FSRS 的間隔）
    private func stepDelay(_ steps: [TimeInterval], step: Int, grade: Grade) -> Int? {
        guard !steps.isEmpty else { return nil }
        let i = min(max(0, step), steps.count - 1)
        let delay: TimeInterval
        switch grade {
        case .again:
            delay = steps[0]
        case .hard:
            if i > 0 {
                delay = steps[i]
            } else if steps.count == 1 {
                delay = min(steps[0] * 1.5, steps[0] + 86_400)
            } else {
                delay = (steps[0] + steps[1]) / 2
            }
        case .good:
            guard i + 1 < steps.count else { return nil }
            delay = steps[i + 1]
        case .easy:
            return nil
        }
        return -Self.seconds(delay)
    }

    private static func seconds(_ delay: TimeInterval) -> Int { max(1, Int(delay.rounded())) }

    private func kind(of phase: CardPhase) -> ReviewEntry.Kind {
        switch phase {
        case .new, .learning: .learning
        case .review: .review
        case .relearning: .relearning
        }
    }

    // MARK: 重播

    /// 依序套用一張卡片的所有紀錄（呼叫端依 `(id, deviceId)` 排好）
    public func replay(_ entries: [ReviewEntry]) -> CardSchedule {
        entries.reduce(into: CardSchedule()) { card, entry in card = apply(entry, to: card) }
    }

    /// 套用一筆紀錄。到期日一律採用紀錄的 `ivl`；記憶狀態用目前的參數重算；
    /// 複習後的狀態由 `ivl` 決定（負數 → learning / relearning，正數 → review）
    public func apply(_ entry: ReviewEntry, to card: CardSchedule) -> CardSchedule {
        var next = card
        guard let grade = entry.grade else {
            switch entry.op {
            case .suspend: next.suspended = true
            case .unsuspend: next.suspended = false
            case .reset:
                next = CardSchedule()
                next.suspended = card.suspended
            case nil: break
            }
            return next
        }

        let date = entry.date
        if let memory = fsrsNext(card, grade: grade, at: date) {
            next.stability = memory.stability
            next.difficulty = memory.difficulty
        }
        if entry.ivl < 0 {
            next.phase = card.phase == .review || card.phase == .relearning ? .relearning : .learning
            let steps = next.phase == .learning ? preset.learningSteps : preset.relearningSteps
            var step = 0
            // 新卡等同 learning 的第 0 步
            if (card.phase == .new ? .learning : card.phase) == next.phase {
                switch grade {
                case .again: step = 0
                case .hard: step = card.step
                case .good, .easy: step = card.step + 1
                }
            }
            next.step = min(step, max(0, steps.count - 1))
            next.due = date.addingTimeInterval(Double(-entry.ivl))
        } else {
            next.phase = .review
            next.step = 0
            next.due = clock.start(ofDay: clock.day(of: date) + entry.ivl)
        }
        if card.phase == .review, grade == .again { next.lapses += 1 }
        next.reps += 1
        next.lastReview = date
        next.lastIvl = entry.ivl
        return next
    }

    // MARK: swift-fsrs

    private struct Outcome {
        var stability: Double
        var difficulty: Double
        /// FSRS 的間隔（天，已含 fuzz 與 Hard ≤ Good < Easy 的限制）
        var days: Int

        init(_ card: Card) {
            stability = card.stability
            difficulty = card.difficulty
            days = max(1, Int(card.scheduledDays))
        }
    }

    /// 四個評分各自的記憶狀態與間隔
    private func fsrsPreview(_ card: CardSchedule, at date: Date) -> [Grade: Outcome] {
        let (input, now) = fsrsInput(card, at: date)
        guard let preview = try? fsrs.repeat(card: input, now: now) else { return [:] }
        var result: [Grade: Outcome] = [:]
        for grade in Grade.allCases {
            if let item = preview[Rating(rawValue: grade.rawValue)!] { result[grade] = Outcome(item.card) }
        }
        return result
    }

    /// 只算一個評分的記憶狀態（重播用；`days` 不使用）。
    /// 記憶狀態只看 S、D、經過天數與評分，與卡片狀態無關；swift-fsrs 對複習卡會算出四個按鈕
    /// （每個數值都經過 `String(format:)`，重播 10 萬筆要好幾秒），所以一律以 learning 狀態計算
    private func fsrsNext(_ card: CardSchedule, grade: Grade, at date: Date) -> Outcome? {
        var (input, now) = fsrsInput(card, at: date)
        if input.state != .new { input.state = .learning }
        return (try? memoryFSRS.next(card: input, now: now, grade: Rating(rawValue: grade.rawValue)!)).map { Outcome($0.card) }
    }

    private func fsrsInput(_ card: CardSchedule, at date: Date) -> (Card, Date) {
        var input = Card(due: date, state: .new)
        if let s = card.stability, let d = card.difficulty, card.phase != .new, let last = card.lastReview {
            input.stability = s
            input.difficulty = d
            input.state = switch card.phase {
            case .new, .learning: .learning
            case .review: .review
            case .relearning: .relearning
            }
            input.lastReview = clock.schedulerDate(last)
            input.reps = card.reps
            input.lapses = card.lapses
        }
        // 時鐘不準的裝置可能早於上次複習：不讓經過時間變成負數
        return (input, max(clock.schedulerDate(date), input.lastReview ?? .distantPast))
    }
}
