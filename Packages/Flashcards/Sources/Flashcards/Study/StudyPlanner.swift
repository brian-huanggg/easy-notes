import Foundation

/// 每日上限、埋藏 sibling、出卡順序。規則照 Anki 的 v3 排程器（見 architecture/flashcards.md「每日上限與佇列」）。
///
/// 不保存任何狀態：今天學過幾張新卡、哪一行今天複習過，都由複習紀錄推得，換日後自動重新計算。
/// 每次作答後以新的狀態重新建立（卡片數量級是數千，計算只要幾毫秒）。
public struct StudyPlanner: Sendable {
    public struct Counts: Equatable, Sendable {
        public var new = 0
        /// learning / relearning，今天內到期的
        public var learning = 0
        public var review = 0

        public init(new: Int = 0, learning: Int = 0, review: Int = 0) {
            self.new = new
            self.learning = learning
            self.review = review
        }

        public var total: Int { new + learning + review }
    }

    /// 標籤篩選一次最多幾張（Anki filtered deck 的預設）
    public static let filteredLimit = 100
    /// 沒有其他卡片時，這段時間內到期的 learning 卡提前出現（Anki 的 learn ahead limit）
    public static let learnAhead: TimeInterval = 20 * 60
    /// 由 lapses 算出的虛擬標籤
    public static let leechTag = "leech"

    public let cards: [StudyCard]
    public let schedules: [String: CardSchedule]
    public let config: SRSConfig
    public let clock: DayClock
    public let now: Date
    /// 路徑 → 筆記的標籤
    public let tags: [String: [String]]

    let today: Int
    /// 今天第一次評分（今天學的新卡）的卡片
    let introducedToday: Set<String>
    /// 今天的 Review 評分次數，依卡片
    let reviewsToday: [String: Int]
    /// note id → 今天評分過的卡片
    let answeredToday: [String: Set<String>]
    /// 最後一次按 Again 是第幾天（自訂複習「忘記的卡」）
    let lastAgainDay: [String: Int]

    public init(cards: [StudyCard], schedules: [String: CardSchedule], history: [String: [ReviewEntry]],
                config: SRSConfig, tags: [String: [String]] = [:], now: Date = Date(),
                timeZone: TimeZone = .current) {
        self.cards = cards
        self.schedules = schedules
        self.config = config
        self.tags = tags
        self.now = now
        let clock = DayClock(timeZone: timeZone, rolloverHour: config.global.rolloverHour)
        let today = clock.day(of: now)
        self.clock = clock
        self.today = today
        var introduced = Set<String>()
        var reviews: [String: Int] = [:]
        var answered: [String: Set<String>] = [:]
        var again: [String: Int] = [:]
        let noteOf = Dictionary(cards.map { ($0.id, $0.noteID) }, uniquingKeysWith: { a, _ in a })
        for (cid, entries) in history {
            // reset 之後重新算新卡
            let start = entries.lastIndex { $0.op == .reset }.map { $0 + 1 } ?? 0
            let graded = entries[start...].filter { $0.grade != nil }
            if let last = graded.last(where: { $0.grade == .again }) { again[cid] = clock.day(of: last.date) }
            guard let first = graded.first, let last = graded.last, clock.day(of: last.date) == today else { continue }
            if clock.day(of: first.date) == today { introduced.insert(cid) }
            reviews[cid] = graded.filter { $0.type == .review && clock.day(of: $0.date) == today }.count
            if let note = noteOf[cid] { answered[note, default: []].insert(cid) }
        }
        introducedToday = introduced
        reviewsToday = reviews
        answeredToday = answered
        lastAgainDay = again
    }

    public func schedule(_ card: StudyCard) -> CardSchedule {
        schedules[card.id] ?? CardSchedule()
    }

    public func preset(_ card: StudyCard) -> Preset {
        config.preset(for: card.deck)
    }

    // MARK: 查詢

    public func counts(_ scope: StudyScope, within allowed: Set<String>? = nil) -> Counts {
        let queue = gather(scope, within: allowed)
        return Counts(new: queue.new.count, learning: queue.learningToday, review: queue.review.count)
    }

    /// 下一張要複習的卡片。`position` = 這次複習已經作答的次數，用來把新卡平均穿插在複習卡之間
    public func next(_ scope: StudyScope, position: Int, within allowed: Set<String>? = nil) -> StudyCard? {
        let queue = gather(scope, within: allowed)
        if let card = queue.learningDue.first { return card }
        let r = queue.review.count
        let n = queue.new.count
        if r > 0, n > 0 {
            let every = max(1, (r + n) / n)
            return (position + 1) % every == 0 ? queue.new[0] : queue.review[0]
        }
        if let card = queue.review.first ?? queue.new.first { return card }
        return queue.learningAhead.first
    }

    /// 標籤篩選開始時決定的卡片：先到期的（learning、複習），再新卡，最多 `filteredLimit` 張
    public func filteredSelection(_ tag: String) -> Set<String> {
        let queue = gather(.tag(tag), within: nil)
        let ordered = queue.learningAll + queue.review + queue.new
        return Set(ordered.prefix(Self.filteredLimit).map(\.id))
    }

    /// 自訂複習開始時決定的卡片（最多 `filteredLimit` 張）；張數也用在 Sheet 的預覽
    public func customSelection(_ study: CustomStudy) -> Set<String> {
        let days = max(1, study.days)
        var candidates = Set<String>()
        for card in cards where study.contains(card) {
            switch study.kind {
            case .forgotten:
                if let day = lastAgainDay[card.id], day > today - days { candidates.insert(card.id) }
            case .reviewAhead:
                let state = schedule(card)
                if state.phase == .review, let due = state.due, clock.day(of: due) <= today + days { candidates.insert(card.id) }
            }
        }
        let queue = gather(.filtered(study), within: candidates)
        return Set((queue.learningAll + queue.review).prefix(Self.filteredLimit).map(\.id))
    }

    /// 卡片的標籤：所在筆記的標籤，加上虛擬標籤 `leech`
    public func tags(of card: StudyCard) -> [String] {
        var result = tags[card.path] ?? []
        if isLeech(card) { result.append(Self.leechTag) }
        return result
    }

    public func isLeech(_ card: StudyCard) -> Bool {
        schedule(card).lapses >= preset(card).leechThreshold
    }

    /// 所有標籤（篩選選單），含有卡片的才列出
    public var availableTags: [String] {
        var set = Set<String>()
        for card in cards { set.formUnion(tags(of: card)) }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 這次作答觸發 Leech：複習卡按 Again，lapses 達到門檻，之後每多門檻的一半再觸發一次（同 Anki）
    public static func triggersLeech(lapses: Int, threshold: Int) -> Bool {
        lapses >= threshold && (lapses - threshold) % max(1, threshold / 2) == 0
    }

    // MARK: 佇列

    struct Queue {
        /// 已到期的 learning 卡，依到期時間
        var learningDue: [StudyCard] = []
        /// 還沒到期、但在 learn ahead 範圍內
        var learningAhead: [StudyCard] = []
        /// 今天內所有 learning 卡（標籤篩選）
        var learningAll: [StudyCard] = []
        var learningToday = 0
        var review: [StudyCard] = []
        var new: [StudyCard] = []
    }

    func gather(_ scope: StudyScope, within allowed: Set<String>?) -> Queue {
        let tomorrow = clock.start(ofDay: today + 1)
        var queue = Queue()
        var learning: [(StudyCard, Date)] = []
        var reviews: [StudyCard] = []
        var news: [StudyCard] = []
        // 自訂複習：選定的複習卡不論是否到期都出現，不出新卡
        let custom: Bool
        if case .filtered = scope { custom = true } else { custom = false }
        for card in cards where contains(scope, card) && allowed?.contains(card.id) != false {
            let state = schedule(card)
            guard !state.suspended else { continue }
            switch state.phase {
            case .learning, .relearning:
                let due = state.due ?? now
                if due < tomorrow { learning.append((card, due)) }
            case .review:
                if custom && allowed != nil { reviews.append(card) }
                else if let due = state.due, clock.day(of: due) <= today { reviews.append(card) }
            case .new:
                if !custom { news.append(card) }
            }
        }
        learning.sort { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
        queue.learningAll = learning.map(\.0)
        queue.learningToday = learning.count
        queue.learningDue = learning.filter { $0.1 <= now }.map(\.0)
        queue.learningAhead = learning.filter { $0.1 > now && $0.1 <= now.addingTimeInterval(Self.learnAhead) }.map(\.0)

        let limited: Bool
        switch scope {
        case .tag, .filtered: limited = false
        case .all, .deck, .unfiled: limited = true
        }
        var limits = Limits(planner: self, scope: scope)
        var takenNotes = Set<String>()

        for card in sortReviews(reviews) {
            let preset = preset(card)
            if preset.buryReviews, buried(card) || takenNotes.contains(card.noteID) { continue }
            if limited {
                guard limits.take(card, new: false) else { continue }
            }
            takenNotes.insert(card.noteID)
            queue.review.append(card)
        }
        for card in sortNew(news) {
            let preset = preset(card)
            if preset.buryNew, buried(card) || takenNotes.contains(card.noteID) { continue }
            if limited {
                guard limits.take(card, new: true) else { continue }
            }
            takenNotes.insert(card.noteID)
            queue.new.append(card)
        }
        return queue
    }

    func contains(_ scope: StudyScope, _ card: StudyCard) -> Bool {
        switch scope {
        case .all: true
        case .deck(let path): card.deck == path || card.deck.hasPrefix(path + "/")
        case .unfiled: card.deck.isEmpty
        case .tag(let tag): tags(of: card).contains { $0.caseInsensitiveCompare(tag) == .orderedSame || $0.lowercased().hasPrefix(tag.lowercased() + "/") }
        case .filtered(let study): study.contains(card)
        }
    }

    /// 同一行今天已經評分過其他卡片
    private func buried(_ card: StudyCard) -> Bool {
        answeredToday[card.noteID]?.contains { $0 != card.id } == true
    }

    private func sortReviews(_ cards: [StudyCard]) -> [StudyCard] {
        cards.map { card -> (StudyCard, Double, Double) in
            let state = schedule(card)
            let key = switch preset(card).reviewOrder {
            case .due: state.due?.timeIntervalSince1970 ?? 0
            case .retrievability: retrievability(state, w: preset(card).w)
            }
            return (card, key, state.due?.timeIntervalSince1970 ?? 0)
        }
        .sorted { ($0.1, $0.2, $0.0.id) < ($1.1, $1.2, $1.0.id) }
        .map(\.0)
    }

    private func sortNew(_ cards: [StudyCard]) -> [StudyCard] {
        cards.map { card -> (StudyCard, String, Int, UInt64) in
            switch preset(card).newOrder {
            case .file: (card, card.path, card.line * 1000 + card.ordinal, 0)
            case .random: (card, "", 0, Self.hash("\(card.id)|\(today)"))
            }
        }
        .sorted { a, b in
            if a.3 != b.3 { return a.3 < b.3 }
            if a.1 != b.1 { return a.1.localizedStandardCompare(b.1) == .orderedAscending }
            return (a.2, a.0.id) < (b.2, b.0.id)
        }
        .map(\.0)
    }

    /// FSRS-6 的可回想率：R = (1 + factor · t / S)^decay
    func retrievability(_ state: CardSchedule, w: [Double]) -> Double {
        guard let s = state.stability, s > 0, let last = state.lastReview else { return 0 }
        let decay = -(w.count > 20 ? w[20] : 0.5)
        let factor = pow(0.9, 1 / decay) - 1
        let t = max(0, now.timeIntervalSince(last) / 86_400)
        return pow(1 + factor * t / s, decay)
    }

    /// FNV-1a 加上 splitmix64 的收尾：隨機新卡順序（同一天內穩定，不受 Swift 每次執行不同的 hash seed 影響）。
    /// 只用 FNV-1a 時最後幾個字元幾乎不影響高位元，換日後順序不會變
    static func hash(_ text: String) -> UInt64 {
        var x = text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        x = (x ^ (x >> 30)) &* 0xbf58_476d_1ce4_e5b9
        x = (x ^ (x >> 27)) &* 0x94d0_49bb_1331_11eb
        return x ^ (x >> 31)
    }
}

/// 每日上限的剩餘數。從所選牌組到卡片所在牌組路徑上的每一層都要還有剩餘
struct Limits {
    private var newLeft: [String: Int] = [:]
    private var reviewLeft: [String: Int] = [:]
    private let planner: StudyPlanner
    private let scope: StudyScope

    init(planner: StudyPlanner, scope: StudyScope) {
        self.planner = planner
        self.scope = scope
    }

    /// 通過上限就扣掉；新卡同時扣複習上限（Anki 23.10 起的預設）
    mutating func take(_ card: StudyCard, new: Bool) -> Bool {
        let chain = chain(for: card.deck)
        for deck in chain {
            if remaining(deck, new: false) <= 0 { return false }
            if new, remaining(deck, new: true) <= 0 { return false }
        }
        for deck in chain {
            reviewLeft[deck] = remaining(deck, new: false) - 1
            if new { newLeft[deck] = remaining(deck, new: true) - 1 }
        }
        return true
    }

    /// 套用上限的牌組：所選牌組到卡片所在牌組。「所有牌組」從最上層牌組開始，根目錄的卡片只看根目錄
    private func chain(for deck: String) -> [String] {
        let start: String
        switch scope {
        case .deck(let path): start = path
        case .unfiled, .tag, .filtered: start = ""
        case .all: start = deck.split(separator: "/").first.map(String.init) ?? ""
        }
        guard !deck.isEmpty, !start.isEmpty else { return [""] }
        var chain = [start]
        var path = start
        for part in deck.dropFirst(start.count).split(separator: "/") {
            path += "/" + part
            chain.append(path)
        }
        return chain
    }

    private mutating func remaining(_ deck: String, new: Bool) -> Int {
        if let left = new ? newLeft[deck] : reviewLeft[deck] { return left }
        let preset = planner.config.preset(for: deck)
        let config = planner.config
        // 今天已經在這個牌組（含子牌組；"" 只算根目錄）做過的
        let inDeck = { (card: StudyCard) in
            deck.isEmpty ? card.deck.isEmpty : card.deck == deck || card.deck.hasPrefix(deck + "/")
        }
        var newDone = 0
        var reviewDone = 0
        for card in planner.cards where inDeck(card) {
            if planner.introducedToday.contains(card.id) { newDone += 1 }
            reviewDone += planner.reviewsToday[card.id] ?? 0
        }
        // 今天學的新卡也算在複習上限內（Anki 23.10 起的預設）
        // 自訂複習「增加今天的上限」
        let newLimit = preset.newPerDay + config.extraLimit(deck, new: true, day: planner.today)
        let reviewLimit = preset.reviewsPerDay + config.extraLimit(deck, new: false, day: planner.today)
        let left = new ? newLimit - newDone : reviewLimit - reviewDone - newDone
        if new { newLeft[deck] = left } else { reviewLeft[deck] = left }
        return left
    }
}
