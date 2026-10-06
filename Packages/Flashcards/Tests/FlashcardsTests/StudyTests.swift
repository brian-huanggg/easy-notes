import EasyNotesCore
import Foundation
import Testing
@testable import Flashcards

private enum NoteKind: DocumentKind {
    static let id = "markdown"
    static let fileExtensions = ["md"]
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
}

// MARK: - 設定（各裝置各寫、欄位 LWW）

struct SettingsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "srs-config-\(UUID().uuidString)")
    var fs: VaultFS { VaultFS(root: root, kinds: try! KindRegistry([NoteKind.self])) }
    static let t0 = Date(timeIntervalSince1970: 1_759_400_000)

    @Test func defaultsWhenNothingWritten() {
        defer { try? FileManager.default.removeItem(at: root) }
        let config = SRSSettings.load(fs)
        #expect(config == SRSConfig())
        #expect(config.preset(for: "日文/N2") == Preset())
        #expect(config.global.rolloverHour == 4)
    }

    /// 兩台裝置改不同欄位 → 都保留；同一欄位 → 較新的勝出
    @Test func twoDevicesMergePerField() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SRSSettings.load(fs)

        var mac = base
        mac.presets["default"]!.newPerDay = 30
        mac.presets["default"]!.desiredRetention = 0.85
        try SRSSettings.save(mac, replacing: base, fs: fs, deviceID: "mac", now: Self.t0)

        var ipad = base
        ipad.presets["default"]!.reviewsPerDay = 150
        ipad.presets["default"]!.desiredRetention = 0.95
        ipad.global.rolloverHour = 5
        try SRSSettings.save(ipad, replacing: base, fs: fs, deviceID: "ipad", now: Self.t0.addingTimeInterval(60))

        let merged = SRSSettings.load(fs)
        let preset = merged.presets["default"]!
        #expect(preset.newPerDay == 30)
        #expect(preset.reviewsPerDay == 150)
        #expect(preset.desiredRetention == 0.95)
        #expect(merged.global.rolloverHour == 5)
        // 沒改的欄位不寫進檔案
        let mine = String(decoding: try fs.read(SRSSettings.path(deviceID: "mac")), as: UTF8.self)
        #expect(!mine.contains("reviewsPerDay"))
    }

    @Test func presetAssignmentInheritsAndFollowsRename() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SRSSettings.load(fs)
        var config = base
        var language = Preset()
        language.name = "語言"
        language.newPerDay = 30
        config.presets["p-lang01"] = language
        config.decks["日文"] = "p-lang01"
        try SRSSettings.save(config, replacing: base, fs: fs, deviceID: "mac", now: Self.t0)

        var loaded = SRSSettings.load(fs)
        #expect(loaded.presetID(for: "日文/N2 文法") == "p-lang01")
        #expect(loaded.presetID(for: "程式") == SRSConfig.defaultPresetID)
        #expect(loaded.preset(for: "日文").name == "語言")

        let renamed = loaded.movingFolder(from: "日文", to: "語言/日本語")
        try SRSSettings.save(renamed, replacing: loaded, fs: fs, deviceID: "mac", now: Self.t0.addingTimeInterval(1))
        loaded = SRSSettings.load(fs)
        #expect(loaded.decks == ["語言/日本語": "p-lang01"])
        #expect(loaded.presetID(for: "語言/日本語/N2") == "p-lang01")
        #expect(loaded.presetID(for: "日文") == SRSConfig.defaultPresetID)
    }

    /// 刪除 preset：使用它的牌組改回繼承上層；另一台裝置較舊的修改不會讓它復活
    @Test func deletedPresetStaysDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SRSSettings.load(fs)
        var config = base
        config.presets["p-med001"] = Preset()
        config.decks["藥理學"] = "p-med001"
        try SRSSettings.save(config, replacing: base, fs: fs, deviceID: "mac", now: Self.t0)

        var ipad = SRSSettings.load(fs)
        let before = ipad
        ipad.presets["p-med001"]!.newPerDay = 5
        try SRSSettings.save(ipad, replacing: before, fs: fs, deviceID: "ipad", now: Self.t0.addingTimeInterval(10))

        var mac = SRSSettings.load(fs)
        let beforeDelete = mac
        mac.removePreset("p-med001")
        try SRSSettings.save(mac, replacing: beforeDelete, fs: fs, deviceID: "mac", now: Self.t0.addingTimeInterval(20))

        let merged = SRSSettings.load(fs)
        #expect(merged.presets["p-med001"] == nil)
        #expect(merged.presetID(for: "藥理學") == SRSConfig.defaultPresetID)
        // default 不能刪
        var keep = merged
        keep.removePreset(SRSConfig.defaultPresetID)
        #expect(keep.presets[SRSConfig.defaultPresetID] != nil)
    }

    /// 相同時間的同一欄位：比 deviceId，任何裝置都得到相同結果
    @Test func tieBreaksByDeviceID() {
        let fields: [String: [SRSSettings.Field]] = [
            "a": [.init(k: ["global", "rolloverHour"], v: .number(3), t: 100)],
            "b": [.init(k: ["global", "rolloverHour"], v: .number(6), t: 100)],
        ]
        #expect(SRSSettings.config(from: SRSSettings.winners(fields)).global.rolloverHour == 6)
    }

    /// 型別不對的欄位用預設值，其他欄位照常
    @Test func ignoresMalformedFields() {
        let fields: [[String]: JSONValue] = [
            ["presets", "default", "newPerDay"]: .string("很多"),
            ["presets", "default", "reviewsPerDay"]: .number(99),
        ]
        let preset = SRSSettings.config(from: fields).presets["default"]!
        #expect(preset.newPerDay == 20)
        #expect(preset.reviewsPerDay == 99)
    }
}

// MARK: - 牌組、上限、佇列

struct StudyTests {
    static let zone = TimeZone(identifier: "Asia/Taipei")!
    /// 台灣時間 2026-03-02 12:00
    static let noon = Date(timeIntervalSince1970: 1_772_424_000)
    static var clock: DayClock { DayClock(timeZone: zone, rolloverHour: 4) }

    /// `count` 張正向卡，放在 `path`，每行一張
    static func notes(_ path: String, _ count: Int, prefix: String) -> [StudyCard] {
        (0..<count).flatMap { i in
            StudyCard.cards(path: path, note: CardNote(id: "c-\(prefix)\(i)", type: .forward, line: i, front: "q\(i)", back: "a\(i)"))
        }
    }

    static func planner(_ cards: [StudyCard], config: SRSConfig = SRSConfig(),
                        schedules: [String: CardSchedule] = [:], history: [String: [ReviewEntry]] = [:],
                        now: Date = noon) -> StudyPlanner {
        StudyPlanner(cards: cards, schedules: schedules, history: history, config: config, now: now, timeZone: zone)
    }

    static func reviewCard(dueDaysAgo: Int = 0) -> CardSchedule {
        var state = CardSchedule()
        state.phase = .review
        state.due = clock.start(ofDay: clock.day(of: noon) - dueDaysAgo)
        state.stability = 10
        state.difficulty = 5
        state.lastReview = noon.addingTimeInterval(-10 * 86_400)
        return state
    }

    @Test func deckTreeFollowsFolders() {
        let cards = Self.notes("日文/N2 文法/a.md", 3, prefix: "g") + Self.notes("日文/N2 單字/b.md", 2, prefix: "v")
            + Self.notes("程式/c.md", 1, prefix: "p") + Self.notes("雜記.md", 1, prefix: "r")
        let tree = Deck.tree(cards)
        #expect(tree.map(\.name) == ["日文", "程式", L("未分類")])
        #expect(tree[0].children.map(\.name) == ["N2 單字", "N2 文法"])
        #expect(tree[0].cardCount == 5)
        #expect(tree[0].noteCount == 5)
        #expect(tree[0].children[0].depth == 1)
        #expect(tree[2].scope == .unfiled)
    }

    @Test func bidirectionalAndClozeCards() {
        let pair = StudyCard.cards(path: "a.md", note: CardNote(id: "c-1", type: .bidirectional, line: 0, front: "中文", back: "Chinese"))
        #expect(pair.map(\.id) == ["c-1", "c-1:r"])
        #expect(pair[1].front == [.init("Chinese")])
        let cloze = StudyCard.cards(path: "a.md", note: CardNote(
            id: "c-2", type: .cloze, line: 1, front: "{{粒線體}}是{{細胞的發電廠}}", back: "", clozes: ["粒線體", "細胞的發電廠"]))
        #expect(cloze.map(\.id) == ["c-2:1", "c-2:2"])
        #expect(cloze[1].front == [.init("粒線體是"), .init(StudyCard.clozeBlank, emphasized: true)])
        #expect(cloze[1].back == [.init("粒線體是"), .init("細胞的發電廠", emphasized: true)])
        #expect(!cloze[0].multiline)
    }

    @Test func multilineClozeShowsBackExtra() {
        let cards = StudyCard.cards(path: "a.md", note: CardNote(
            id: "c-3", type: .cloze, line: 0, endLine: 2, front: "理論\n- {{信任}}", back: "補充", clozes: ["信任"]))
        #expect(cards[0].multiline)
        #expect(cards[0].front == [.init("理論\n- "), .init(StudyCard.clozeBlank, emphasized: true)])
        #expect(cards[0].back == [.init("理論\n- "), .init("信任", emphasized: true), .init("\n\n補充")])
    }

    @Test func typedAnswerComparison() {
        let cloze = StudyCard.cards(path: "a.md", note: CardNote(
            id: "c-4", type: .cloze, line: 0, front: "建立 pod：{{kubectl run  nginx}}，補充 {{x}}", back: "",
            clozes: ["kubectl run  nginx", "x"]))
        #expect(cloze[0].clozeAnswer == "kubectl run  nginx")
        #expect(cloze[1].clozeAnswer == "x")
        #expect(cloze[0].matchesTypedAnswer("  Kubectl run nginx "))
        #expect(!cloze[0].matchesTypedAnswer("kubectl run"))
        #expect(!cloze[0].matchesTypedAnswer("   "))
        let basic = StudyCard.cards(path: "a.md", note: CardNote(id: "c-5", type: .forward, line: 0, front: "Q", back: "A"))
        #expect(basic[0].clozeAnswer == nil)
        #expect(!basic[0].matchesTypedAnswer("A"))
    }

    /// 母牌組上限涵蓋子牌組：日文 new 30，兩個子牌組各 20 → 從日文開始只有 30 張；從子牌組開始各 20 張
    @Test func parentLimitCoversChildren() {
        let cards = Self.notes("日文/文法/a.md", 25, prefix: "g") + Self.notes("日文/單字/b.md", 25, prefix: "v")
        var config = SRSConfig()
        var parent = Preset()
        parent.newPerDay = 30
        config.presets["p-parent"] = parent
        config.decks["日文"] = "p-parent"
        config.decks["日文/文法"] = SRSConfig.defaultPresetID
        config.decks["日文/單字"] = SRSConfig.defaultPresetID
        let planner = Self.planner(cards, config: config)
        #expect(planner.counts(.deck("日文")).new == 30)
        #expect(planner.counts(.deck("日文/文法")).new == 20)
        #expect(planner.counts(.deck("日文/單字")).new == 20)
        // 「所有牌組」每個最上層牌組各自套用
        #expect(planner.counts(.all).new == 30)
    }

    /// 今天學過的新卡扣掉上限；也算在複習上限內
    @Test func studiedTodayReducesLimits() {
        let cards = Self.notes("a/n.md", 30, prefix: "n") + Self.notes("a/r.md", 10, prefix: "r")
        var schedules: [String: CardSchedule] = [:]
        var history: [String: [ReviewEntry]] = [:]
        for card in cards.prefix(5) {
            var state = CardSchedule()
            state.phase = .learning
            state.due = Self.noon.addingTimeInterval(3600)
            schedules[card.id] = state
            history[card.id] = [ReviewEntry(id: Self.noon.addingTimeInterval(-600).millis, cid: card.id, ease: 3,
                                            ivl: -600, lastIvl: 0, time: 1000, type: .learning)]
        }
        for card in cards.suffix(10) { schedules[card.id] = Self.reviewCard() }
        var config = SRSConfig()
        config.presets["default"]!.reviewsPerDay = 12
        let counts = Self.planner(cards, config: config, schedules: schedules, history: history).counts(.deck("a"))
        // 新卡 20 − 5；複習上限 12 − 今天的新卡 5 = 7 → 複習 7 張，新卡也被擋到 0
        #expect(counts.review == 7)
        #expect(counts.new == 0)
        #expect(counts.learning == 5)
    }

    /// 同一行今天複習過其他卡片 → 依設定埋藏；佇列中同一行只放一張
    @Test func buriesSiblings() {
        let pair = StudyCard.cards(path: "a.md", note: CardNote(id: "c-1", type: .bidirectional, line: 0, front: "x", back: "y"))
        let cloze = StudyCard.cards(path: "a.md", note: CardNote(id: "c-2", type: .cloze, line: 1, front: "{{a}}{{b}}", back: "", clozes: ["a", "b"]))
        var config = SRSConfig()
        #expect(Self.planner(pair + cloze, config: config).counts(.unfiled).new == 4)
        config.presets["default"]!.buryNew = true
        #expect(Self.planner(pair + cloze, config: config).counts(.unfiled).new == 2)

        // c-1 今天評分過 → c-1:r 埋藏
        let history = ["c-1": [ReviewEntry(id: Self.noon.addingTimeInterval(-60).millis, cid: "c-1", ease: 3, ivl: 1,
                                           lastIvl: 0, time: 0, type: .learning)]]
        var schedules = ["c-1": Self.reviewCard()]
        schedules["c-1"]!.due = Self.clock.start(ofDay: Self.clock.day(of: Self.noon) + 1)
        let planner = Self.planner(pair + cloze, config: config, schedules: schedules, history: history)
        #expect(planner.counts(.unfiled).new == 1)
        #expect(planner.next(.unfiled, position: 0)?.id == "c-2:1")
    }

    /// 已到期的 learning 卡優先；新卡平均穿插在複習卡之間；最後是 20 分鐘內到期的 learning 卡
    @Test func queueOrder() {
        let cards = Self.notes("a.md", 6, prefix: "x")
        var schedules: [String: CardSchedule] = [:]
        for card in cards.prefix(4) { schedules[card.id] = Self.reviewCard() }
        var learning = CardSchedule()
        learning.phase = .learning
        learning.due = Self.noon.addingTimeInterval(-1)
        schedules["c-x5"] = learning
        let planner = Self.planner(cards, schedules: schedules)
        #expect(planner.next(.unfiled, position: 0)?.id == "c-x5")

        schedules["c-x5"]!.due = Self.noon.addingTimeInterval(600)
        let later = Self.planner(cards, schedules: schedules)
        // 4 張複習、1 張新卡 → 每 5 張出一張新卡
        let order = (0..<5).map { later.next(.unfiled, position: $0)?.id }
        #expect(order[4] == "c-x4")
        #expect(order[0] == "c-x0")

        let onlyLearning = Self.planner([cards[5]], schedules: ["c-x5": schedules["c-x5"]!])
        #expect(onlyLearning.next(.unfiled, position: 0)?.id == "c-x5")
        schedules["c-x5"]!.due = Self.noon.addingTimeInterval(3600)
        #expect(Self.planner([cards[5]], schedules: ["c-x5": schedules["c-x5"]!]).next(.unfiled, position: 0) == nil)
    }

    /// 標籤篩選：跨牌組、不受上限限制；`leech` 由 lapses 算出
    @Test func tagFilter() {
        let cards = Self.notes("a/x.md", 30, prefix: "a") + Self.notes("b/y.md", 2, prefix: "b")
        var leech = Self.reviewCard()
        leech.lapses = 8
        let planner = StudyPlanner(cards: cards, schedules: ["c-b1": leech], history: [:], config: SRSConfig(),
                                   tags: ["a/x.md": ["考試"], "b/y.md": ["考試/期中"]], now: Self.noon, timeZone: Self.zone)
        #expect(planner.counts(.tag("考試")).new == 31)
        #expect(planner.filteredSelection("考試").count == 32)
        #expect(planner.counts(.tag("leech")).review == 1)
        #expect(planner.availableTags == ["leech", "考試", "考試/期中"])
        #expect(StudyPlanner.triggersLeech(lapses: 8, threshold: 8))
        #expect(!StudyPlanner.triggersLeech(lapses: 9, threshold: 8))
        #expect(StudyPlanner.triggersLeech(lapses: 12, threshold: 8))
    }

    @Test func randomNewOrderIsStableWithinADay() {
        let cards = Self.notes("a.md", 20, prefix: "r")
        var config = SRSConfig()
        config.presets["default"]!.newOrder = .random
        let a = Self.planner(cards, config: config).gather(.unfiled, within: nil).new.map(\.id)
        let b = Self.planner(cards, config: config, now: Self.noon.addingTimeInterval(3600)).gather(.unfiled, within: nil).new.map(\.id)
        let tomorrow = Self.planner(cards, config: config, now: Self.noon.addingTimeInterval(86_400)).gather(.unfiled, within: nil).new.map(\.id)
        #expect(a == b)
        #expect(a != tomorrow)
        #expect(a != cards.map(\.id))
    }
}

// MARK: - 自訂複習

struct CustomStudyTests {
    static var noon: Date { StudyTests.noon }
    static var today: Int { StudyTests.clock.day(of: noon) }

    /// 增加今天的上限：只在當天有效；從母牌組開始時母牌組的上限仍然適用
    @Test func extendedLimitsApplyOnlyToday() {
        let cards = StudyTests.notes("a/b/x.md", 40, prefix: "n")
        var config = SRSConfig()
        config.extendNew["a/b"] = LimitExtension(day: Self.today, n: 10)
        let planner = StudyTests.planner(cards, config: config)
        #expect(planner.counts(.deck("a/b")).new == 30)
        #expect(planner.counts(.deck("a")).new == 20)
        config.extendNew["a"] = LimitExtension(day: Self.today, n: 5)
        #expect(StudyTests.planner(cards, config: config).counts(.deck("a")).new == 25)
        // 昨天加的不算
        config.extendNew["a/b"] = LimitExtension(day: Self.today - 1, n: 10)
        #expect(StudyTests.planner(cards, config: config).counts(.deck("a/b")).new == 20)

        var reviews: [String: CardSchedule] = [:]
        for card in cards { reviews[card.id] = StudyTests.reviewCard() }
        var reviewConfig = SRSConfig()
        reviewConfig.presets["default"]!.reviewsPerDay = 10
        reviewConfig.extendReview["a/b"] = LimitExtension(day: Self.today, n: 15)
        #expect(StudyTests.planner(cards, config: reviewConfig, schedules: reviews).counts(.deck("a/b")).review == 25)
    }

    /// 兩台裝置各加新卡、複習 → 都保留
    @Test func extensionsSyncPerField() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "srs-extend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = VaultFS(root: root, kinds: try KindRegistry([NoteKind.self]))
        let base = SRSSettings.load(fs)
        var mac = base
        mac.extendNew["日文"] = LimitExtension(day: Self.today, n: 10)
        try SRSSettings.save(mac, replacing: base, fs: fs, deviceID: "mac", now: Self.noon)
        var ipad = base
        ipad.extendReview["日文"] = LimitExtension(day: Self.today, n: 50)
        try SRSSettings.save(ipad, replacing: base, fs: fs, deviceID: "ipad", now: Self.noon.addingTimeInterval(60))
        let merged = SRSSettings.load(fs)
        #expect(merged.extraLimit("日文", new: true, day: Self.today) == 10)
        #expect(merged.extraLimit("日文", new: false, day: Self.today) == 50)
        #expect(merged.extraLimit("日文", new: true, day: Self.today + 1) == 0)
        // 不影響其他設定
        #expect(merged.presets == SRSConfig().presets)
    }

    private static func again(_ cid: String, daysAgo: Int) -> ReviewEntry {
        ReviewEntry(id: noon.addingTimeInterval(Double(-daysAgo) * 86_400).millis, cid: cid, ease: 1, ivl: -600,
                    lastIvl: 3, time: 1000, type: .review)
    }

    /// 忘記的卡：最近 N 天（含今天）按過 Again，依牌組篩選；選定後不論是否到期都出現，不出新卡
    @Test func forgottenCards() {
        let cards = StudyTests.notes("a/x.md", 3, prefix: "a") + StudyTests.notes("b/y.md", 1, prefix: "b")
        var notDue = StudyTests.reviewCard()
        notDue.due = StudyTests.clock.start(ofDay: Self.today + 2)
        let schedules = ["c-a0": notDue, "c-a1": notDue, "c-b0": notDue]
        let history = ["c-a0": [Self.again("c-a0", daysAgo: 0)], "c-a1": [Self.again("c-a1", daysAgo: 2)],
                       "c-b0": [Self.again("c-b0", daysAgo: 0)]]
        let planner = StudyTests.planner(cards, schedules: schedules, history: history)
        #expect(planner.customSelection(CustomStudy(.forgotten, days: 1, deck: "a")) == ["c-a0"])
        #expect(planner.customSelection(CustomStudy(.forgotten, days: 3, deck: "a")) == ["c-a0", "c-a1"])
        let all = CustomStudy(.forgotten, days: 1, deck: nil)
        let selected = planner.customSelection(all)
        #expect(selected == ["c-a0", "c-b0"])
        let counts = planner.counts(.filtered(all), within: selected)
        #expect(counts.review == 2)
        #expect(counts.new == 0)
        // 一般複習時沒到期的卡片不出現
        #expect(planner.counts(.deck("a")).review == 0)
    }

    /// 提前複習：N 天內到期的複習卡（含已到期），不受每日上限限制
    @Test func reviewAhead() {
        let cards = StudyTests.notes("a/x.md", 4, prefix: "a")
        var soon = StudyTests.reviewCard()
        soon.due = StudyTests.clock.start(ofDay: Self.today + 1)
        var later = StudyTests.reviewCard()
        later.due = StudyTests.clock.start(ofDay: Self.today + 5)
        let schedules = ["c-a0": StudyTests.reviewCard(dueDaysAgo: 1), "c-a1": soon, "c-a2": later]
        var config = SRSConfig()
        config.presets["default"]!.reviewsPerDay = 0
        let planner = StudyTests.planner(cards, config: config, schedules: schedules)
        let study = CustomStudy(.reviewAhead, days: 1, deck: nil)
        let selected = planner.customSelection(study)
        #expect(selected == ["c-a0", "c-a1"])
        #expect(planner.counts(.filtered(study), within: selected).review == 2)
        #expect(planner.customSelection(CustomStudy(.reviewAhead, days: 5, deck: "a")).count == 3)
        #expect(planner.counts(.deck("a")).review == 0)
    }

    /// 提前作答寫成 `type: 3`，不算在今天的複習數內；到期的照常是 `type: 1`
    @Test func earlyReviewIsFiltered() throws {
        let scheduler = Scheduler(clock: StudyTests.clock)
        var early = StudyTests.reviewCard()
        early.due = StudyTests.clock.start(ofDay: Self.today + 3)
        let entry = try #require(scheduler.preview(early, cid: "c-a0", now: Self.noon)[.good])
        #expect(entry.type == .filtered)
        #expect(entry.ivl > 0)
        #expect(scheduler.preview(StudyTests.reviewCard(), cid: "c-a0", now: Self.noon)[.good]?.type == .review)
        #expect(ReviewEntry(line: Substring(entry.line)) == entry)

        // 第一筆是昨天的 learning、今天是 type 3 → 不扣複習上限
        let cards = StudyTests.notes("a/x.md", 2, prefix: "a")
        let history = ["c-a0": [ReviewEntry(id: Self.noon.addingTimeInterval(-86_400 * 5).millis, cid: "c-a0", ease: 3,
                                            ivl: 5, lastIvl: 0, time: 0, type: .learning), entry]]
        var config = SRSConfig()
        config.presets["default"]!.reviewsPerDay = 1
        let planner = StudyTests.planner(cards, config: config,
                                         schedules: ["c-a1": StudyTests.reviewCard()], history: history)
        #expect(planner.counts(.deck("a")).review == 1)

        // Again 一樣算 lapse
        let lapse = try #require(scheduler.preview(early, cid: "c-a0", now: Self.noon)[.again])
        #expect(scheduler.apply(lapse, to: early).lapses == 1)
    }
}

// MARK: - 復原

struct UndoTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "srs-undo-\(UUID().uuidString)")
    var fs: VaultFS { VaultFS(root: root, kinds: try! KindRegistry([NoteKind.self])) }

    @Test func removesOnlyMatchingLastLines() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ReviewLog(fs: fs, deviceID: "mac")
        let a = ReviewEntry(id: 1, cid: "c-a", ease: 3, ivl: -600, lastIvl: 0, time: 100, type: .learning)
        let b = ReviewEntry(id: 2, cid: "c-b", ease: 1, ivl: -60, lastIvl: 0, time: 100, type: .learning)
        try log.append([a])
        try log.append([b])
        #expect(try !log.removeLast([a]))
        #expect(try log.removeLast([b]))
        #expect(try ReviewLog.load(fs) == ["c-a": [a]])
        #expect(try log.removeLast([a]))
        #expect(try ReviewLog.load(fs).isEmpty)
        #expect(try !log.removeLast([a]))
    }
}
