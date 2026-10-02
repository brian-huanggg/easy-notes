import Foundation

/// 一張可以複習的卡片（一筆 note 依類型產生一或多張）
public struct StudyCard: Identifiable, Equatable, Sendable {
    /// 卡片 id（`^id` + 後綴），複習紀錄的 `cid`
    public let id: String
    public let noteID: String
    public let path: String
    /// 第幾行（從 0 起算）
    public let line: Int
    public let type: CardType
    /// 同一行的第幾張：正向 0、反向 1；克漏字為第幾個 `{{}}`
    public let ordinal: Int
    public let front: [Segment]
    public let back: [Segment]

    /// 卡片正反面的一段文字；`emphasized` = 克漏字的答案或挖空處
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let emphasized: Bool

        public init(_ text: String, emphasized: Bool = false) {
            self.text = text
            self.emphasized = emphasized
        }
    }

    /// 所屬牌組 = 所在資料夾（Vault 根目錄為 ""）
    public var deck: String { (path as NSString).deletingLastPathComponent }

    /// 克漏字挖空處的顯示
    public static let clozeBlank = "[…]"

    /// 一筆 note 產生的卡片，順序同 `CardNote.cardIDs`
    public static func cards(path: String, note: CardNote) -> [StudyCard] {
        guard let noteID = note.id else { return [] }
        func make(_ id: String, _ ordinal: Int, _ front: [Segment], _ back: [Segment]) -> StudyCard {
            StudyCard(id: id, noteID: noteID, path: path, line: note.line, type: note.type, ordinal: ordinal,
                      front: front, back: back)
        }
        switch note.type {
        case .forward:
            return [make(noteID, 0, [Segment(note.front)], [Segment(note.back)])]
        case .bidirectional:
            return [make(noteID, 0, [Segment(note.front)], [Segment(note.back)]),
                    make(noteID + ":r", 1, [Segment(note.back)], [Segment(note.front)])]
        case .cloze:
            let segments = CardSyntax.clozeSegments(note.front)
            return note.clozes.indices.map { target in
                let front = segments.map { part in
                    part.cloze == target ? Segment(clozeBlank, emphasized: true) : Segment(part.text)
                }
                let back = segments.map { Segment($0.text, emphasized: $0.cloze == target) }
                return make("\(noteID):\(target + 1)", target, merge(front), merge(back))
            }
        }
    }

    /// 相鄰而且強調與否相同的片段合併
    private static func merge(_ segments: [Segment]) -> [Segment] {
        segments.reduce(into: []) { result, segment in
            if let last = result.last, last.emphasized == segment.emphasized {
                result[result.count - 1] = Segment(last.text + segment.text, emphasized: last.emphasized)
            } else {
                result.append(segment)
            }
        }
    }
}
