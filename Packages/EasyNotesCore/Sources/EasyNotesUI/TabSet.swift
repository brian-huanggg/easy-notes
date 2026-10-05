import Foundation

/// The tab list (like a browser): holds only each tab's state and no editor, so background tabs take almost no memory.
/// There is always at least one tab; `State` is decided by the shell (the app uses location + back / forward history)
public struct TabSet<State> {
    public struct Tab: Identifiable {
        public let id: UUID
        public var state: State
    }

    public private(set) var tabs: [Tab]
    public private(set) var activeID: UUID

    public init(_ state: State) {
        let tab = Tab(id: UUID(), state: state)
        tabs = [tab]
        activeID = tab.id
    }

    /// Restore: empty `states` is equivalent to a single `fallback`; an out-of-range `active` takes the last one
    public init(restoring states: [State], active: Int, fallback: State) {
        tabs = states.map { Tab(id: UUID(), state: $0) }
        if tabs.isEmpty { tabs = [Tab(id: UUID(), state: fallback)] }
        activeID = tabs[min(max(active, 0), tabs.count - 1)].id
    }

    public var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }

    public var active: State {
        get { tabs[activeIndex].state }
        set { tabs[activeIndex].state = newValue }
    }

    /// Adds to the right of the current tab and switches to it
    @discardableResult
    public mutating func open(_ state: State) -> UUID {
        let tab = Tab(id: UUID(), state: state)
        tabs.insert(tab, at: activeIndex + 1)
        activeID = tab.id
        return tab.id
    }

    public mutating func activate(_ id: UUID) {
        if tabs.contains(where: { $0.id == id }) { activeID = id }
    }

    /// Switches in order (⌃Tab); wraps from the end to the start
    public mutating func activate(offset: Int) {
        let count = tabs.count
        activeID = tabs[((activeIndex + offset) % count + count) % count].id
    }

    /// Closes a tab: closing the current tab switches to the right (the left if none); after the last tab is closed it is replaced by `blank`
    public mutating func close(_ id: UUID, blank: @autoclosure () -> State) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            let tab = Tab(id: UUID(), state: blank())
            tabs = [tab]
            activeID = tab.id
        } else if id == activeID {
            activeID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Closes the other tabs
    public mutating func closeOthers(keeping id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tabs = [tab]
        activeID = id
    }

    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
    }

    /// Updates each tab's state (rename, move)
    public mutating func update(_ change: (inout State) -> Void) {
        for index in tabs.indices { change(&tabs[index].state) }
    }

    public func firstTab(where match: (State) -> Bool) -> Tab? {
        tabs.first { match($0.state) }
    }
}
