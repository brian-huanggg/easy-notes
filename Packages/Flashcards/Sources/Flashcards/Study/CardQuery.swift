import Foundation

/// 卡片瀏覽（Anki 的 Browse）的篩選與排序。只讀卡片與重播結果，不改任何東西
public struct CardQuery: Equatable, Sendable {
    public enum State: Hashable, Sendable, CaseIterable {
        case all, new, learning, review, due, suspended, leech
    }

    public enum Order: Hashable, Sendable, CaseIterable {
        /// 依路徑、行號（筆記中的順序）
        case note
        /// 到期日早的在前，新卡最後
        case due
        /// 遺忘次數多的在前
        case lapses
    }

    /// 資料夾路徑（含子資料夾）；nil = 所有牌組，"" = 未分類（只含根目錄）
    public var deck: String?
    public var state = State.all
    public var order = Order.note
    /// 比對正反面文字與標籤（不分大小寫）；`#考試` 只比對標籤
    public var search = ""

    public init(deck: String? = nil) {
        self.deck = deck
    }

    public func run(_ planner: StudyPlanner) -> [StudyCard] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let tagOnly = needle.hasPrefix("#")
        let term = tagOnly ? String(needle.dropFirst()) : needle
        let today = planner.today
        let matches = planner.cards.filter { card in
            if let deck {
                if deck.isEmpty ? !card.deck.isEmpty : card.deck != deck && !card.deck.hasPrefix(deck + "/") { return false }
            }
            let schedule = planner.schedule(card)
            switch state {
            case .all: break
            case .new: if schedule.phase != .new || schedule.suspended { return false }
            case .learning: if schedule.phase != .learning && schedule.phase != .relearning || schedule.suspended { return false }
            case .review: if schedule.phase != .review || schedule.suspended { return false }
            case .due:
                guard !schedule.suspended, schedule.phase != .new, let due = schedule.due,
                      planner.clock.day(of: due) <= today else { return false }
            case .suspended: if !schedule.suspended { return false }
            case .leech: if !planner.isLeech(card) { return false }
            }
            guard !term.isEmpty else { return true }
            let tags = planner.tags(of: card)
            if tags.contains(where: { $0.localizedCaseInsensitiveContains(term) }) { return true }
            if tagOnly { return false }
            return Self.text(card.front).localizedCaseInsensitiveContains(term)
                || Self.text(card.back).localizedCaseInsensitiveContains(term)
        }
        let byNote = { (a: StudyCard, b: StudyCard) -> Bool in
            let order = a.path.localizedStandardCompare(b.path)
            if order != .orderedSame { return order == .orderedAscending }
            return (a.line, a.ordinal) < (b.line, b.ordinal)
        }
        switch order {
        case .note:
            return matches.sorted(by: byNote)
        case .due:
            return matches.sorted { a, b in
                let da = planner.schedule(a).due ?? .distantFuture
                let db = planner.schedule(b).due ?? .distantFuture
                return da == db ? byNote(a, b) : da < db
            }
        case .lapses:
            return matches.sorted { a, b in
                let la = planner.schedule(a).lapses
                let lb = planner.schedule(b).lapses
                return la == lb ? byNote(a, b) : la > lb
            }
        }
    }

    public static func text(_ segments: [StudyCard.Segment]) -> String {
        segments.map(\.text).joined()
    }
}
