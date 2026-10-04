import Foundation

/// 分頁清單（類似瀏覽器）：只放每個分頁的狀態，不持有編輯器，所以背景分頁幾乎不佔記憶體。
/// 永遠至少有一個分頁；`State` 由外殼決定（App 用位置 + 上一頁 / 下一頁歷史）
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

    /// 還原：`states` 為空時等同只有一個 `fallback`；`active` 超出範圍時取最後一個
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

    /// 在目前分頁右邊新增並切過去
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

    /// 依順序切換（⌃Tab）；到尾端回到開頭
    public mutating func activate(offset: Int) {
        let count = tabs.count
        activeID = tabs[((activeIndex + offset) % count + count) % count].id
    }

    /// 關閉分頁：關的是目前分頁時切到右邊（沒有就左邊）；最後一個分頁關掉後換成 `blank`
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

    /// 關閉其他分頁
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

    /// 更新每個分頁的狀態（改名、搬移）
    public mutating func update(_ change: (inout State) -> Void) {
        for index in tabs.indices { change(&tabs[index].state) }
    }

    public func firstTab(where match: (State) -> Bool) -> Tab? {
        tabs.first { match($0.state) }
    }
}
