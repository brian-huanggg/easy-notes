import Foundation

/// 編輯器（JS）送來的修改，在儲存格編輯結束時才送，不是每個按鍵。
/// 列以 row id 指定（排序或篩選後仍能對回原本的列）；JS 新增的列由 JS 配負數 id，不會與 Swift 配的衝突。
///
/// JSON：`{"op":"set","row":3,"col":1,"value":"x"}`、`{"op":"insertRows","before":5,"rows":[{"id":-1,"cells":["a"]}]}`
/// （`before` 為 null = 附加在最後）、`{"op":"deleteRows","rows":[1,2]}`、`{"op":"insertColumn","at":2}`、
/// `{"op":"deleteColumn","at":2}`、`{"op":"order","rows":[0,2,1]}`
public enum SheetOp: Equatable, Sendable {
    public struct NewRow: Equatable, Sendable, Decodable {
        public var id: Int
        public var cells: [String]
    }

    case set(row: Int, column: Int, value: String)
    case insertRows(before: Int?, rows: [NewRow])
    case deleteRows([Int])
    case insertColumn(at: Int)
    case deleteColumn(at: Int)
    case order([Int])
}

extension SheetOp: Decodable {
    private enum Key: String, CodingKey {
        case op, row, col, value, before, rows, at
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .op) {
        case "set":
            self = .set(row: try c.decode(Int.self, forKey: .row), column: try c.decode(Int.self, forKey: .col),
                        value: try c.decode(String.self, forKey: .value))
        case "insertRows":
            self = .insertRows(before: try c.decodeIfPresent(Int.self, forKey: .before),
                               rows: try c.decode([NewRow].self, forKey: .rows))
        case "deleteRows": self = .deleteRows(try c.decode([Int].self, forKey: .rows))
        case "insertColumn": self = .insertColumn(at: try c.decode(Int.self, forKey: .at))
        case "deleteColumn": self = .deleteColumn(at: try c.decode(Int.self, forKey: .at))
        case "order": self = .order(try c.decode([Int].self, forKey: .rows))
        case let op: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(op)")
        }
    }
}

extension SheetDocument {
    /// 依序套用；任何一個失敗就停在那裡（前面的已套用）
    public mutating func apply(_ ops: [SheetOp]) throws(EditError) {
        for op in ops {
            switch op {
            case .set(let row, let column, let value):
                try setCell(row: row, column: column, to: value)
            case .insertRows(let before, let rows):
                var at = records.count
                if let before {
                    guard let i = index(ofRow: before) else { throw .unknownRow(before) }
                    at = i
                }
                try insertRows(rows.map(\.cells), at: at, ids: rows.map(\.id))
            case .deleteRows(let ids):
                try deleteRows(ids)
            case .insertColumn(let at):
                try insertColumn(at: at)
            case .deleteColumn(let at):
                try deleteColumn(at: at)
            case .order(let ids):
                try reorderRows(ids)
            }
        }
    }
}
