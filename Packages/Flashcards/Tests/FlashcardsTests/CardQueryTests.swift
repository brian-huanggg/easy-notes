import Foundation
import Testing
@testable import Flashcards

struct CardQueryTests {
    static let cards = StudyTests.notes("日文/N2/a.md", 3, prefix: "a") + StudyTests.notes("日文/b.md", 1, prefix: "b")
        + StudyTests.notes("雜記.md", 1, prefix: "r")

    static func planner() -> StudyPlanner {
        var suspended = StudyTests.reviewCard()
        suspended.suspended = true
        var future = StudyTests.reviewCard()
        future.due = StudyTests.clock.start(ofDay: StudyTests.clock.day(of: StudyTests.noon) + 3)
        future.lapses = 9
        var learning = CardSchedule()
        learning.phase = .relearning
        learning.due = StudyTests.noon.addingTimeInterval(600)
        let schedules = ["c-a0": StudyTests.reviewCard(dueDaysAgo: 2), "c-a1": future, "c-a2": suspended, "c-b0": learning]
        return StudyPlanner(cards: cards, schedules: schedules, history: [:], config: SRSConfig(),
                            tags: ["日文/b.md": ["考試/期中"]], now: StudyTests.noon, timeZone: StudyTests.zone)
    }

    @Test func filtersByDeckAndState() {
        let planner = Self.planner()
        // 依 Finder 的順序：日文/b.md 在 日文/N2/a.md 之前
        #expect(CardQuery().run(planner).map(\.id) == ["c-b0", "c-a0", "c-a1", "c-a2", "c-r0"])
        #expect(CardQuery(deck: "日文/N2").run(planner).count == 3)
        #expect(CardQuery(deck: "").run(planner).map(\.id) == ["c-r0"])
        var query = CardQuery(deck: "日文")
        query.state = .due
        #expect(query.run(planner).map(\.id) == ["c-b0", "c-a0"])
        query.state = .suspended
        #expect(query.run(planner).map(\.id) == ["c-a2"])
        query.state = .review
        #expect(query.run(planner).map(\.id) == ["c-a0", "c-a1"])
        query.state = .learning
        #expect(query.run(planner).map(\.id) == ["c-b0"])
        query.state = .leech
        #expect(query.run(planner).map(\.id) == ["c-a1"])
        query.state = .new
        #expect(CardQuery().run(planner).count == 5)
        #expect(query.run(planner).isEmpty)
    }

    @Test func searchAndOrder() {
        let planner = Self.planner()
        var query = CardQuery()
        query.search = "Q2"
        #expect(query.run(planner).map(\.id) == ["c-a2"])
        query.search = "#期中"
        #expect(query.run(planner).map(\.id) == ["c-b0"])
        query.search = "#q0"
        #expect(query.run(planner).isEmpty)
        query.search = ""
        query.order = .due
        #expect(query.run(planner).map(\.id) == ["c-a0", "c-a2", "c-b0", "c-a1", "c-r0"])
        query.order = .lapses
        #expect(query.run(planner).first?.id == "c-a1")
    }
}
