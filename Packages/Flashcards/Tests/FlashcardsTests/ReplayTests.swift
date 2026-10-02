import EasyNotesCore
import Foundation
import Testing
@testable import Flashcards

private enum NoteKind: DocumentKind {
    static let id = "markdown"
    static let fileExtensions = ["md"]
    static func template(title: String) -> Data { Data("# \(title)\n".utf8) }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
}

struct ReplayTests {
    static let taipei = DayClock(timeZone: TimeZone(identifier: "Asia/Taipei")!, rolloverHour: 4)
    let root = FileManager.default.temporaryDirectory.appending(path: "srs-\(UUID().uuidString)")
    var fs: VaultFS { VaultFS(root: root, kinds: try! KindRegistry([NoteKind.self])) }

    /// 台灣時間 2026-03-02 的某個時刻
    static func taipei(day: Int = 2, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = taipei.timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    /// 模擬作答：預覽 → 選一個按鈕 → 套用（App 的流程）
    static func study(_ scheduler: Scheduler, cid: String, _ answers: [(Grade, Date)]) -> (CardSchedule, [ReviewEntry]) {
        var card = CardSchedule()
        var log: [ReviewEntry] = []
        for (grade, date) in answers {
            var entry = scheduler.preview(card, cid: cid, now: date)[grade]!
            entry.time = 4_000
            card = scheduler.apply(entry, to: card)
            log.append(entry)
        }
        return (card, log)
    }

    // MARK: 換日時間

    @Test func dayStartsAtRolloverHourInLocalTime() {
        let clock = Self.taipei
        #expect(clock.day(of: Self.taipei(3, 59)) + 1 == clock.day(of: Self.taipei(4, 1)))
        // UTC 午夜 = 台灣早上 8 點，不換日
        #expect(clock.day(of: Self.taipei(7, 59)) == clock.day(of: Self.taipei(8, 1)))
        #expect(clock.day(of: Self.taipei(4, 0)) == clock.day(of: Self.taipei(day: 3, 3, 59)))
        let day = clock.day(of: Self.taipei(12))
        #expect(clock.start(ofDay: day) == Self.taipei(4))
        #expect(clock.start(ofDay: day + 3) == Self.taipei(day: 5, 4))
        for n in [-800_000, -1, 0, 1, 20_000, 400_000] {
            let (y, m, d) = DayClock.civilFromDays(n)
            #expect(DayClock.daysFromCivil(y, m, d) == n)
        }
    }

    /// 經過的天數照換日時間計算：同一天 → 短期記憶公式；跨過凌晨 4 點 → 經過一天
    @Test func elapsedDaysFollowRollover() {
        let scheduler = Scheduler(clock: Self.taipei, fuzz: false)
        func stability(_ second: Date) -> Double {
            let (card, _) = Self.study(scheduler, cid: "c", [(.good, Self.taipei(3, 0)), (.good, second)])
            return card.stability!
        }
        let sameDay = stability(Self.taipei(3, 58))
        let nextDay = stability(Self.taipei(4, 1))
        #expect(sameDay != nextDay)
        // 早上 7:59 與 8:01（UTC 午夜前後）是同一天
        let a = Self.study(scheduler, cid: "c", [(.good, Self.taipei(7, 59)), (.good, Self.taipei(8, 1))]).0
        let b = Self.study(scheduler, cid: "c", [(.good, Self.taipei(7, 0)), (.good, Self.taipei(7, 2))]).0
        #expect(a.stability == b.stability)
    }

    @Test func reviewDueIsRolloverOfTargetDay() {
        let scheduler = Scheduler(clock: Self.taipei, fuzz: false)
        let (card, log) = Self.study(scheduler, cid: "c", [(.easy, Self.taipei(23))])
        #expect(card.phase == .review)
        #expect(card.due == Self.taipei(day: 2 + log[0].ivl, 4))
        // 凌晨 2 點還算前一天
        let (early, earlyLog) = Self.study(scheduler, cid: "c", [(.easy, Self.taipei(day: 3, 2))])
        #expect(early.due == Self.taipei(day: 2 + earlyLog[0].ivl, 4))
    }

    // MARK: 重播

    /// 作答當下的狀態 = 日後重播紀錄的狀態（fuzz 開啟）
    @Test func liveStateEqualsReplay() {
        let scheduler = Scheduler(clock: Self.taipei)
        var answers: [(Grade, Date)] = [(.again, Self.taipei(9)), (.good, Self.taipei(9, 1)), (.good, Self.taipei(9, 11))]
        for day in [5, 12, 30, 31] {
            answers.append((day == 30 ? .again : .good, Self.taipei(day: day, 10)))
        }
        answers.append((.good, Self.taipei(day: 31, 10, 20)))
        let (live, log) = Self.study(scheduler, cid: "c", answers)
        #expect(scheduler.replay(log) == live)
        #expect(live.lapses == 1)
        #expect(live.reps == answers.count)
        #expect(live.phase == .review)
    }

    /// 兩台裝置的紀錄，檔案讀取順序不同也得到相同狀態
    @Test func replayIsDeterministicAcrossDevices() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let scheduler = Scheduler(clock: Self.taipei)
        let mac = ReviewLog(fs: fs, deviceID: "MAC"), ipad = ReviewLog(fs: fs, deviceID: "IPAD")
        let (_, first) = Self.study(scheduler, cid: "c-aaaaaa", [(.good, Self.taipei(9)), (.good, Self.taipei(9, 10))])
        try mac.append(first)
        // iPad 同步後接著複習，同一時間 Mac 複習另一張卡
        var card = scheduler.replay(try ReviewLog.load(fs)["c-aaaaaa"]!)
        var entry = scheduler.preview(card, cid: "c-aaaaaa", now: Self.taipei(day: 5, 9))[.hard]!
        try ipad.append([entry])
        card = scheduler.apply(entry, to: card)
        entry = scheduler.preview(CardSchedule(), cid: "c-bbbbbb", now: Self.taipei(day: 5, 9))[.good]!
        try mac.append([entry])

        let history = try ReviewLog.load(fs)
        #expect(history["c-aaaaaa"]?.count == 3)
        #expect(scheduler.replay(history)["c-aaaaaa"] == card)

        // 另一台裝置：檔名不同、順序不同，結果相同
        let other = FileManager.default.temporaryDirectory.appending(path: "srs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        let otherFS = VaultFS(root: other, kinds: fs.kinds)
        try otherFS.write(try fs.read(ipad.path), to: ipad.path)
        try otherFS.write(try fs.read(mac.path), to: mac.path)
        #expect(Scheduler(clock: Self.taipei).replay(try ReviewLog.load(otherFS)) == scheduler.replay(history))
    }

    /// 換參數：到期日與狀態不變（採用紀錄的 ivl），記憶狀態重算
    @Test func changingParametersKeepsDueAndRecomputesMemory() {
        let original = Scheduler(clock: Self.taipei)
        let (card, log) = Self.study(original, cid: "c", [
            (.good, Self.taipei(9)), (.good, Self.taipei(9, 10)), (.good, Self.taipei(day: 6, 9)), (.again, Self.taipei(day: 20, 9)),
        ])
        var preset = Preset()
        preset.w = [0.4, 0.9, 3.1, 10.4, 6.8, 0.6, 2.5, 0.02, 1.6, 0.12, 1.0,
                    1.7, 0.08, 0.3, 1.9, 0.45, 2.2, 0.6, 0.15, 0.1, 0.25]
        preset.desiredRetention = 0.8
        let replayed = Scheduler(preset: preset, clock: Self.taipei).replay(log)
        #expect(replayed.due == card.due)
        #expect(replayed.phase == card.phase)
        #expect(replayed.step == card.step)
        #expect(replayed.lapses == card.lapses)
        #expect(replayed.stability != card.stability)
        #expect(replayed.difficulty != card.difficulty)
    }

    @Test func manualEvents() {
        let scheduler = Scheduler(clock: Self.taipei)
        var (card, log) = Self.study(scheduler, cid: "c", [(.easy, Self.taipei(9))])
        log.append(.manual(.suspend, cid: "c", at: Self.taipei(10)))
        card = scheduler.replay(log)
        #expect(card.suspended && card.phase == .review)
        log.append(.manual(.reset, cid: "c", at: Self.taipei(11)))
        card = scheduler.replay(log)
        #expect(card.phase == .new && card.suspended && card.stability == nil && card.reps == 0 && card.due == nil)
        log.append(.manual(.unsuspend, cid: "c", at: Self.taipei(12)))
        #expect(scheduler.replay(log) == CardSchedule())
    }

    // MARK: 紀錄檔

    @Test func logFileRoundTripAndTolerance() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ReviewLog(fs: fs, deviceID: "MAC")
        let a = ReviewEntry(id: 1_000, cid: "c-a:r", ease: 3, ivl: -600, lastIvl: 0, time: 5_320, type: .learning)
        try log.append([a])
        #expect(String(decoding: try fs.read(log.path), as: UTF8.self) ==
                #"{"cid":"c-a:r","ease":3,"id":1000,"ivl":-600,"lastIvl":0,"time":5320,"type":0}"# + "\n")

        // 寫到一半的行、損壞的行、未知的 op 與欄位
        let url = fs.url(for: log.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":2000,"cid":"c-a:r","ea"#.utf8))
        try handle.close()
        let b = ReviewEntry(id: 3_000, cid: "c-a:r", ease: 4, ivl: 3, lastIvl: -600, time: 0, type: .learning)
        try log.append([b])
        try fs.write(Data((
            #"{"id":2500,"cid":"c-a:r","ease":0,"ivl":0,"lastIvl":0,"time":0,"type":4,"op":"flag"}"# + "\n" +
            #"{"id":2600,"cid":"c-a:r","ease":0,"ivl":0,"lastIvl":0,"time":0,"type":4,"op":"suspend","future":1}"# + "\n" +
            "not json\n" + a.line + "\n"   // 與 MAC 重複的一筆（例如衝突副本）
        ).utf8), to: "\(ReviewLog.folder)/IPAD.jsonl")

        let history = try ReviewLog.load(fs)
        #expect(history["c-a:r"]?.map(\.id) == [1_000, 2_600, 3_000])
        #expect(history["c-a:r"]?[1].op == .suspend)
    }

    /// 刪掉索引重建後，卡片與狀態都相同；整行搬到別篇筆記後歷史不變
    @Test func statesSurviveIndexRebuildAndMovedLines() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let scheduler = Scheduler(clock: Self.taipei)
        try fs.write(Data("# 生物\n\n- 光合作用發生在 :: 葉綠體 ^c-aaaaaa\n- 中文 ;; Chinese ^c-bbbbbb\n".utf8), to: "生物.md")
        let log = ReviewLog(fs: fs, deviceID: "MAC")
        try log.append(Self.study(scheduler, cid: "c-aaaaaa", [(.good, Self.taipei(9)), (.good, Self.taipei(day: 4, 9))]).1)
        try log.append(Self.study(scheduler, cid: "c-bbbbbb:r", [(.again, Self.taipei(9)), (.easy, Self.taipei(9, 2))]).1)

        func states(_ index: VaultIndex) async throws -> [String: CardSchedule] {
            let history = try ReviewLog.load(fs)
            var result: [String: CardSchedule] = [:]
            for (_, note) in try await CardIndexer.notes(in: index) {
                for cid in note.cardIDs { result[cid] = scheduler.replay(history[cid] ?? []) }
            }
            return result
        }

        var index = try VaultIndex(fs: fs, contributors: [CardIndexer()])
        try await index.sync()
        let before = try await states(index)
        #expect(before.count == 3)
        #expect(before["c-bbbbbb"] == CardSchedule())
        #expect(before["c-aaaaaa"]?.phase == .review)

        // 刪掉索引重建
        try FileManager.default.removeItem(at: fs.url(for: "\(VaultFS.metaFolder)/cache"))
        index = try VaultIndex(fs: fs, contributors: [CardIndexer()])
        try await index.sync()
        #expect(try await states(index) == before)

        // 整行搬到另一篇
        try fs.write(Data("# 生物\n\n- 中文 ;; Chinese ^c-bbbbbb\n".utf8), to: "生物.md")
        try fs.write(Data("# 植物\n\n- 光合作用發生在 :: 葉綠體 ^c-aaaaaa\n".utf8), to: "植物/植物.md")
        _ = try await index.sync(paths: ["生物.md", "植物/植物.md"])
        #expect(try await index.paths(withKey: "c-aaaaaa", contributor: CardIndexer.contributorID) == ["植物/植物.md"])
        #expect(try await states(index) == before)
    }

    /// 重播量級：1,000 張卡、2 萬筆紀錄（2026-10-02 量測：10 萬筆在 release 約 1.3 秒）
    @Test func replayPerformance() {
        let scheduler = Scheduler(clock: Self.taipei)
        var history: [String: [ReviewEntry]] = [:]
        for n in 0..<1_000 {
            var answers: [(Grade, Date)] = [(.good, Self.taipei(9)), (.good, Self.taipei(9, 10))]
            for k in 1...18 { answers.append((k % 7 == 0 ? .again : .good, Self.taipei(day: 2 + k * 3, 9))) }
            history["c-\(n)"] = Self.study(scheduler, cid: "c-\(n)", answers).1
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = scheduler.replay(history) }
        print("replay 20k entries: \(elapsed)")
        #expect(history.values.map(\.count).reduce(0, +) == 20_000)
    }
}
