import EasyNotesCore
import EasyNotesUI
import Foundation
import Observation

/// 複習面板的狀態：卡片（來自索引）、紀錄與重播結果、設定、進行中的複習。
///
/// 不是編輯器，但以 `EditorController` 註冊：`attach` 取得 Vault，`vaultChanged` 得知 md 或其他裝置的紀錄變動，
/// `moved` 讓資料夾改名時 preset 的指定跟著搬。重播與讀檔在背景進行，結果只放記憶體。
@MainActor @Observable
public final class ReviewStore: EditorController {
    public static let shared = ReviewStore()

    /// 一次複習
    public struct Session: Equatable {
        public let scope: StudyScope
        public let title: String
        /// 標籤篩選、自訂複習開始時選定的卡片；nil = 依牌組與上限。
        /// 自訂複習中畢業（回到 Review）的卡片會移除，否則沒到期的卡片會一直重複出現
        var allowed: Set<String>?
        public var current: StudyCard?
        public var showingAnswer = false
        /// 這次已經作答的次數
        public var answered = 0
        /// 開始時的剩餘張數（進度條）
        public let initialTotal: Int
        var shownAt = Date()
        /// 這次寫入的紀錄，復原時從後面刪
        var undo: [(card: StudyCard, entries: [ReviewEntry])] = []

        public var canUndo: Bool { !undo.isEmpty }

        public static func == (a: Session, b: Session) -> Bool {
            a.scope == b.scope && a.current == b.current && a.showingAnswer == b.showingAnswer && a.answered == b.answered
                && a.undo.count == b.undo.count
        }
    }

    public private(set) var cards: [StudyCard] = []
    public private(set) var config = SRSConfig()
    public private(set) var planner = StudyPlanner(cards: [], schedules: [:], history: [:], config: SRSConfig())
    public private(set) var decks: [Deck] = []
    /// 每個牌組（含 `.all`）套用上限後的張數
    public private(set) var counts: [StudyScope: StudyPlanner.Counts] = [:]
    public private(set) var loaded = false
    public var session: Session?
    /// 一次性的提示（Leech、無法復原）
    public var notice: String?
    /// 牌組列表收合的資料夾（本機）
    public var collapsed: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "review.collapsed") }
    }

    @ObservationIgnored private weak var vaultSession: (any DocumentSession)?
    @ObservationIgnored private var deviceID: String?
    @ObservationIgnored private var schedules: [String: CardSchedule] = [:]
    @ObservationIgnored private var history: [String: [ReviewEntry]] = [:]
    @ObservationIgnored private var tags: [String: [String]] = [:]
    /// 索引中的卡片 note（匯出給 Anki）
    @ObservationIgnored private var notes: [(path: String, note: CardNote)] = []
    @ObservationIgnored private var cardsTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    /// 卡片圖片：路徑 → （修改時間, 圖片）
    @ObservationIgnored private var images: [String: (modified: Date?, image: PlatformImage)] = [:]

    private init() {
        collapsed = Set(UserDefaults.standard.stringArray(forKey: "review.collapsed") ?? [])
    }

    /// 側邊欄 badge：所有牌組的待複習 + learning（已套用上限）
    public var dueCount: Int? {
        guard loaded, let all = counts[.all] else { return nil }
        let due = all.review + all.learning
        return due > 0 ? due : nil
    }

    private var fs: VaultFS? { vaultSession?.vault }

    // MARK: EditorController

    public func attach(_ session: any DocumentSession) {
        vaultSession = session
        deviceID = try? session.vault.deviceID()
        Task {
            config = SRSSettings.load(session.vault)
            await reloadCards()
            await reloadHistory(replayAll: true)
            loaded = true
            rebuild()
        }
        // learning 卡到期、換日時更新數字
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.rebuild()
            }
        }
    }

    public func vaultChanged(_ paths: Set<String>) {
        let meta = paths.filter { $0.hasPrefix(ReviewLog.folder + "/") }
        if meta.contains(where: { $0.hasSuffix(".config.json") }), let fs {
            let old = config
            config = SRSSettings.load(fs)
            if schedulingChanged(old, config) { scheduleHistoryReload(replayAll: true) } else { rebuild() }
        }
        if meta.contains(where: { $0.hasSuffix(".jsonl") }) { scheduleHistoryReload(replayAll: false) }
        if paths.contains(where: { !$0.hasPrefix(VaultFS.metaFolder + "/") }) {
            cardsTask?.cancel()
            cardsTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await reloadCards()
                rebuild()
            }
        }
    }

    /// App 內改名或搬移資料夾：preset 的指定跟著搬
    public func moved(from: String, to: String) {
        let moved = config.movingFolder(from: from, to: to)
        guard moved != config else { return }
        save(moved)
    }

    /// 卡片中的 `![[x.png]]`：經 `resourceReader` 在背景讀取（`Attachments/` 找不到時改找舊版的 `附件/`），
    /// 依路徑 + 修改時間快取
    func cardImage(_ path: String) async -> PlatformImage? {
        guard let session = vaultSession else { return nil }
        let legacy = Attachments.legacyPath(for: path)
        let modified = session.modified(path) ?? legacy.flatMap { session.modified($0) }
        if let hit = images[path], hit.modified == modified { return hit.image }
        let reader = session.resourceReader
        var data = await reader(path)
        if data == nil, let legacy { data = await reader(legacy) }
        guard let data, let image = PlatformImage(data: data) else { return nil }
        if images.count > 100 { images.removeAll() }
        images[path] = (modified, image)
        return image
    }

    // MARK: 載入

    private func reloadCards() async {
        guard let index = vaultSession?.index else { return }
        let notes = (try? await CardIndexer.notes(in: index)) ?? []
        self.notes = notes
        cards = notes.flatMap { StudyCard.cards(path: $0.path, note: $0.note) }
        tags = (try? await index.fileTags()) ?? [:]
        decks = Deck.tree(cards)
    }

    private func scheduleHistoryReload(replayAll: Bool) {
        historyTask?.cancel()
        historyTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await reloadHistory(replayAll: replayAll)
            rebuild()
        }
    }

    /// 讀取所有裝置的紀錄並重播；`replayAll` = false 時只重播紀錄有變動的卡片
    private func reloadHistory(replayAll: Bool) async {
        guard let fs else { return }
        let oldHistory = history
        let oldSchedules = schedules
        let config = config
        let decks = Dictionary(cards.map { ($0.id, $0.deck) }, uniquingKeysWith: { a, _ in a })
        let clock = DayClock(rolloverHour: config.global.rolloverHour)
        let result = await Task.detached(priority: .userInitiated) { () -> ([String: [ReviewEntry]], [String: CardSchedule])? in
            guard let loaded = try? ReviewLog.load(fs) else { return nil }
            var schedulers: [String: Scheduler] = [:]
            var schedules: [String: CardSchedule] = [:]
            for (cid, entries) in loaded {
                if !replayAll, oldHistory[cid] == entries, let existing = oldSchedules[cid] {
                    schedules[cid] = existing
                    continue
                }
                let presetID = config.presetID(for: decks[cid] ?? "")
                let scheduler = schedulers[presetID] ?? Scheduler(preset: config.presets[presetID] ?? Preset(), clock: clock)
                schedulers[presetID] = scheduler
                schedules[cid] = scheduler.replay(entries)
            }
            return (loaded, schedules)
        }.value
        guard let result else { return }
        history = result.0
        schedules = result.1
    }

    private func schedulingChanged(_ a: SRSConfig, _ b: SRSConfig) -> Bool {
        a.global.rolloverHour != b.global.rolloverHour || a.decks != b.decks
            || a.presets.mapValues(\.schedulingFields) != b.presets.mapValues(\.schedulingFields)
    }

    /// 以目前的狀態重新計算各牌組的數字與複習中的下一張
    private func rebuild() {
        planner = StudyPlanner(cards: cards, schedules: schedules, history: history, config: config, tags: tags)
        var counts: [StudyScope: StudyPlanner.Counts] = [.all: planner.counts(.all)]
        func visit(_ deck: Deck) {
            counts[deck.scope] = planner.counts(deck.scope)
            deck.children.forEach(visit)
        }
        decks.forEach(visit)
        self.counts = counts
        if var session, !session.showingAnswer || session.current == nil {
            // 作答前的卡片可能已被刪掉或改到別的牌組
            if session.current.map({ card in !cards.contains { $0.id == card.id } }) ?? true {
                session.current = next(for: session)
                session.shownAt = Date()
            }
            self.session = session
        }
    }

    // MARK: 複習

    public func counts(_ scope: StudyScope) -> StudyPlanner.Counts {
        if let cached = counts[scope] { return cached }
        if let allowed = session?.allowed, session?.scope == scope {
            return planner.counts(scope, within: allowed)
        }
        return planner.counts(scope)
    }

    public func start(_ scope: StudyScope, title: String) {
        rebuild()
        var allowed: Set<String>?
        switch scope {
        case .tag(let tag): allowed = planner.filteredSelection(tag)
        case .filtered(let study): allowed = planner.customSelection(study)
        case .all, .deck, .unfiled: break
        }
        let total = planner.counts(scope, within: allowed).total
        var session = Session(scope: scope, title: title, allowed: allowed, initialTotal: total)
        session.current = next(for: session)
        self.session = session
    }

    public func end() {
        session = nil
        rebuild()
    }

    /// 這次複習還剩幾張（上方的佇列數字）
    public var sessionCounts: StudyPlanner.Counts {
        guard let session else { return .init() }
        return planner.counts(session.scope, within: session.allowed)
    }

    public func showAnswer() {
        guard session?.current != nil else { return }
        session?.showingAnswer = true
    }

    /// 目前卡片四個按鈕的紀錄（`ivl` = 下次間隔）
    public func previews() -> [Grade: ReviewEntry] {
        guard let card = session?.current else { return [:] }
        return scheduler(for: card).preview(planner.schedule(card), cid: card.id, now: Date())
    }

    public func schedule(of card: StudyCard) -> CardSchedule { planner.schedule(card) }

    public func tags(of card: StudyCard) -> [String] { planner.tags(of: card) }

    public func answer(_ grade: Grade) {
        guard var session, let card = session.current, session.showingAnswer, let deviceID, let fs else { return }
        let now = Date()
        let scheduler = scheduler(for: card)
        let preset = config.preset(for: card.deck)
        let before = planner.schedule(card)
        guard var entry = scheduler.preview(before, cid: card.id, now: now)[grade] else { return }
        entry.time = min(60_000, max(0, Int(now.timeIntervalSince(session.shownAt) * 1000)))
        var entries = [entry]
        var state = scheduler.apply(entry, to: before)
        // 提前複習（`type: 3`）按 Again 也是 lapse
        if before.phase == .review, grade == .again,
           StudyPlanner.triggersLeech(lapses: state.lapses, threshold: preset.leechThreshold) {
            if preset.leechAction == .suspend {
                let suspend = ReviewEntry.manual(.suspend, cid: card.id, at: now)
                entries.append(suspend)
                state = scheduler.apply(suspend, to: state)
                notice = L("這張卡片已遺忘 \(state.lapses) 次，標為 Leech 並暫停")
            } else {
                notice = L("這張卡片已遺忘 \(state.lapses) 次，標為 Leech")
            }
        }
        do {
            try ReviewLog(fs: fs, deviceID: deviceID).append(entries)
        } catch {
            notice = L("無法寫入複習紀錄：\(error.localizedDescription)")
            return
        }
        history[card.id, default: []] += entries
        schedules[card.id] = state
        session.undo.append((card, entries))
        if case .filtered = session.scope, state.phase == .review { session.allowed?.remove(card.id) }
        session.answered += 1
        session.showingAnswer = false
        self.session = session
        vaultSession?.metaChanged()
        advance()
    }

    /// 刪掉本機紀錄檔的最後一筆作答，卡片回到作答前
    public func undo() {
        guard var session, let last = session.undo.last, let deviceID, let fs else { return }
        let removed = (try? ReviewLog(fs: fs, deviceID: deviceID).removeLast(last.entries)) ?? false
        guard removed else {
            notice = L("紀錄檔已有新的內容，無法復原")
            session.undo.removeAll()
            self.session = session
            return
        }
        var entries = history[last.card.id] ?? []
        entries.removeLast(min(entries.count, last.entries.count))
        history[last.card.id] = entries.isEmpty ? nil : entries
        schedules[last.card.id] = entries.isEmpty ? nil : scheduler(for: last.card).replay(entries)
        session.undo.removeLast()
        if case .filtered = session.scope { session.allowed?.insert(last.card.id) }
        session.answered = max(0, session.answered - 1)
        session.current = last.card
        session.showingAnswer = false
        session.shownAt = Date()
        self.session = session
        vaultSession?.metaChanged()
        rebuild()
    }

    /// 開啟卡片所在的筆記並捲到該行；複習保留，回到面板時繼續
    public func editCurrentNote() {
        guard let card = session?.current else { return }
        vaultSession?.open(card.path, line: card.line)
    }

    private func advance() {
        rebuild()
        guard var session else { return }
        session.current = next(for: session)
        session.shownAt = Date()
        self.session = session
    }

    private func next(for session: Session) -> StudyCard? {
        planner.next(session.scope, position: session.answered, within: session.allowed)
    }

    private func scheduler(for card: StudyCard) -> Scheduler {
        Scheduler(preset: config.preset(for: card.deck), clock: DayClock(rolloverHour: config.global.rolloverHour))
    }

    // MARK: 自訂複習

    /// 自訂複習會加入幾張卡片（Sheet 的預覽）
    public func customCount(_ study: CustomStudy) -> Int {
        planner.customSelection(study).count
    }

    /// 這個牌組今天已經多加的張數
    public func extraLimit(_ deck: String, new: Bool) -> Int {
        config.extraLimit(deck, new: new, day: today)
    }

    /// 增加今天的上限：`new` / `review` 是今天總共多加幾張（不是累加），跟著設定檔同步
    public func extendLimits(_ deck: String, new: Int, review: Int) {
        var updated = config
        let day = today
        updated.extendNew[deck] = LimitExtension(day: day, n: max(0, new))
        updated.extendReview[deck] = LimitExtension(day: day, n: max(0, review))
        save(updated)
    }

    private var today: Int { DayClock(rolloverHour: config.global.rolloverHour).day(of: Date()) }

    // MARK: 卡片瀏覽

    /// 暫停、恢復、重設：寫成手動事件（`type: 4`），不改 md。已經是目標狀態的卡片略過
    public func apply(_ op: ReviewEntry.Op, to cards: [StudyCard]) {
        guard let deviceID, let fs else { return }
        let now = Date()
        let targets = cards.filter { card in
            let state = planner.schedule(card)
            switch op {
            case .suspend: return !state.suspended
            case .unsuspend: return state.suspended
            case .reset: return state.phase != .new
            }
        }
        guard !targets.isEmpty else { return }
        // 同一毫秒的多筆以卡片 id 區分，重播順序依 (id, 檔名, 行)
        let entries = targets.map { ReviewEntry.manual(op, cid: $0.id, at: now) }
        do {
            try ReviewLog(fs: fs, deviceID: deviceID).append(entries)
        } catch {
            notice = L("無法寫入複習紀錄：\(error.localizedDescription)")
            return
        }
        for (card, entry) in zip(targets, entries) {
            history[card.id, default: []].append(entry)
            schedules[card.id] = scheduler(for: card).apply(entry, to: planner.schedule(card))
        }
        vaultSession?.metaChanged()
        rebuild()
    }

    /// 開啟卡片所在的筆記並捲到該行
    public func open(_ card: StudyCard) {
        vaultSession?.open(card.path, line: card.line)
    }

    // MARK: 匯出

    /// 匯出給 Anki：牌組（含子牌組；"" = 只有根目錄，nil = 全部）的卡片，依筆記類型拆成三個檔
    public func ankiExport(deck: String?) -> [AnkiExport.File] {
        let selected = notes.filter { item in
            guard let deck else { return true }
            let folder = (item.path as NSString).deletingLastPathComponent
            return deck.isEmpty ? folder.isEmpty : folder == deck || folder.hasPrefix(deck + "/")
        }
        return AnkiExport.files(selected, tags: tags)
    }

    // MARK: 設定

    /// 寫入這台裝置的設定檔；排程參數有變時重新重播
    public func save(_ new: SRSConfig) {
        guard let fs, let deviceID else { return }
        let old = config
        do {
            guard try SRSSettings.save(new, replacing: old, fs: fs, deviceID: deviceID) else { return }
        } catch {
            notice = L("無法儲存設定：\(error.localizedDescription)")
            return
        }
        config = SRSSettings.load(fs)
        vaultSession?.metaChanged()
        if schedulingChanged(old, config) { scheduleHistoryReload(replayAll: true) } else { rebuild() }
    }
}
