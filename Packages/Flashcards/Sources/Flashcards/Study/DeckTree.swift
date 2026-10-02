import Foundation

/// 牌組 = 資料夾。只列出含有卡片的資料夾與它們的上層；Vault 根目錄的卡片是「未分類」（`path == ""`）
public struct Deck: Identifiable, Equatable, Sendable {
    public var id: String { path }
    /// 資料夾路徑；"" = 未分類（只含根目錄的卡片，不含子資料夾）
    public let path: String
    public var children: [Deck]
    /// 含子牌組
    public var cardCount: Int
    public var noteCount: Int

    public var name: String { path.isEmpty ? L("未分類") : (path as NSString).lastPathComponent }
    public var depth: Int { path.isEmpty ? 0 : path.split(separator: "/").count - 1 }

    /// 開始複習這個牌組時的範圍
    public var scope: StudyScope { path.isEmpty ? .unfiled : .deck(path) }

    /// 依資料夾樹建立；子牌組依名稱排序（同 Finder），未分類放在最後
    public static func tree(_ cards: [StudyCard]) -> [Deck] {
        var cardsByFolder: [String: (cards: Int, notes: Set<String>)] = [:]
        for card in cards {
            cardsByFolder[card.deck, default: (0, [])].cards += 1
            cardsByFolder[card.deck, default: (0, [])].notes.insert(card.noteID)
        }
        var folders = Set<String>()
        for folder in cardsByFolder.keys where !folder.isEmpty {
            var path = folder
            while !path.isEmpty {
                folders.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        func build(_ path: String) -> Deck {
            let children = folders.filter { ($0 as NSString).deletingLastPathComponent == path }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map(build)
            let own = cardsByFolder[path]
            var notes = own?.notes ?? []
            func collect(_ deck: Deck) { notes.formUnion(deck.noteIDs) }
            children.forEach(collect)
            var deck = Deck(path: path, children: children,
                            cardCount: (own?.cards ?? 0) + children.reduce(0) { $0 + $1.cardCount },
                            noteCount: notes.count)
            deck.noteIDs = notes
            return deck
        }
        var top = folders.filter { !$0.contains("/") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(build)
        if let root = cardsByFolder[""] {
            var unfiled = Deck(path: "", children: [], cardCount: root.cards, noteCount: root.notes.count)
            unfiled.noteIDs = root.notes
            top.append(unfiled)
        }
        return top
    }

    /// 只用來計算 `noteCount`
    private var noteIDs: Set<String> = []

    public static func == (a: Deck, b: Deck) -> Bool {
        a.path == b.path && a.children == b.children && a.cardCount == b.cardCount && a.noteCount == b.noteCount
    }

    init(path: String, children: [Deck], cardCount: Int, noteCount: Int) {
        self.path = path
        self.children = children
        self.cardCount = cardCount
        self.noteCount = noteCount
    }
}

/// 一次複習的範圍
public enum StudyScope: Hashable, Sendable {
    /// 所有牌組（「開始複習」、側邊欄 badge）：每個最上層牌組各自套用上限
    case all
    /// 資料夾與其子資料夾
    case deck(String)
    /// Vault 根目錄的卡片（不含子資料夾）
    case unfiled
    /// 標籤篩選（Anki 的 filtered deck）：跨牌組、不受每日上限限制
    case tag(String)
}
