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
        #expect(tree.map(\.name) == ["日文", "程式", "未分類"])
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
