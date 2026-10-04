import Testing
@testable import EasyNotesUI

struct TabSetTests {
    private func make(_ names: String...) -> TabSet<String> {
        var set = TabSet(names[0])
        for name in names.dropFirst() { set.open(name) }
        return set
    }

    @Test func openInsertsAfterActiveAndActivates() {
        var set = make("a", "b", "c")
        set.activate(set.tabs[0].id)
        set.open("x")
        #expect(set.tabs.map(\.state) == ["a", "x", "b", "c"])
        #expect(set.active == "x")
    }

    @Test func closingActiveSelectsRightThenLeft() {
        var set = make("a", "b", "c")
        set.activate(set.tabs[1].id)
        set.close(set.activeID, blank: "-")
        #expect(set.active == "c")
        set.close(set.activeID, blank: "-")
        #expect(set.active == "a")
    }

    @Test func closingBackgroundTabKeepsActive() {
        var set = make("a", "b", "c")
        let active = set.activeID
        set.close(set.tabs[0].id, blank: "-")
        #expect(set.activeID == active)
        #expect(set.tabs.map(\.state) == ["b", "c"])
    }

    @Test func closingLastTabLeavesBlank() {
        var set = TabSet("a")
        set.close(set.activeID, blank: "blank")
        #expect(set.tabs.map(\.state) == ["blank"])
        #expect(set.active == "blank")
    }

    @Test func offsetWraps() {
        var set = make("a", "b", "c")
        set.activate(offset: 1)
        #expect(set.active == "a")
        set.activate(offset: -1)
        #expect(set.active == "c")
    }

    @Test func restoreClampsActive() {
        let set = TabSet(restoring: ["a", "b"], active: 9, fallback: "-")
        #expect(set.active == "b")
        let empty = TabSet(restoring: [], active: 0, fallback: "-")
        #expect(empty.tabs.map(\.state) == ["-"])
    }

    @Test func closeOthersAndMove() {
        var set = make("a", "b", "c")
        set.move(set.tabs[2].id, to: 0)
        #expect(set.tabs.map(\.state) == ["c", "a", "b"])
        set.closeOthers(keeping: set.tabs[1].id)
        #expect(set.tabs.map(\.state) == ["a"])
        #expect(set.active == "a")
    }
}
