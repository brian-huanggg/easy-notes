import Foundation
import SQLite3

/// Anki collection（SQLite）中匯入需要的資料，全部讀進記憶體。
/// 支援 schema 18（`notetypes`、`fields`、`templates`、`decks` 資料表）與 schema 11（`col` 的 JSON 欄位）
public struct AnkiCollection: Sendable {
    public struct NoteType: Sendable, Equatable {
        public var name: String
        public var cloze: Bool
        public var fields: [String]
        public var templates: Int
    }

    public struct Note: Sendable, Equatable {
        public var id: Int64
        public var typeID: Int64
        public var fields: [String]
        public var tags: [String]
    }

    public struct Card: Sendable, Equatable {
        public var id: Int64
        public var noteID: Int64
        /// 牌組名稱的每一層（`A::B` → `["A", "B"]`）；在篩選牌組中的卡片取原本的牌組
        public var deck: [String]
        public var ord: Int
        /// 0 New、1 Learning、2 Review、3 Relearning
        public var type: Int
        /// -1 暫停、-2 / -3 埋藏
        public var queue: Int
        /// 修改時間（秒）
        public var modified: Int64
    }

    public struct Review: Sendable, Equatable {
        public var id: Int64
        public var cardID: Int64
        public var ease: Int
        public var ivl: Int
        public var lastIvl: Int
        public var time: Int
        public var type: Int
    }

    public var noteTypes: [Int64: NoteType]
    public var notes: [Note]
    public var cards: [Card]
    public var reviews: [Review]
    /// Anki 的換日時間（點）；讀不到時為 nil
    public var rolloverHour: Int?

    public init(noteTypes: [Int64: NoteType], notes: [Note], cards: [Card], reviews: [Review], rolloverHour: Int? = nil) {
        self.noteTypes = noteTypes
        self.notes = notes
        self.cards = cards
        self.reviews = reviews
        self.rolloverHour = rolloverHour
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// 以唯讀開啟 SQLite 檔
    init(path: String) throws {
        let db = try ReadOnlyDB(path: path)
        let modern = try db.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'notetypes'").count == 1
        var deckNames: [Int64: [String]] = [:]
        if modern {
            var fields: [Int64: [(Int, String)]] = [:]
            for row in try db.rows("SELECT ntid, ord, name FROM fields") {
                fields[row.int(0), default: []].append((Int(row.int(1)), row.text(2)))
            }
            var templates: [Int64: Int] = [:]
            for row in try db.rows("SELECT ntid FROM templates") { templates[row.int(0), default: 0] += 1 }
            var types: [Int64: NoteType] = [:]
            for row in try db.rows("SELECT id, name, config FROM notetypes") {
                let id = row.int(0)
                types[id] = NoteType(name: row.text(1), cloze: Protobuf.varint(field: 1, in: row.blob(2)) == 1,
                                     fields: (fields[id] ?? []).sorted { $0.0 < $1.0 }.map(\.1),
                                     templates: templates[id] ?? 0)
            }
            noteTypes = types
            for row in try db.rows("SELECT id, name FROM decks") {
                deckNames[row.int(0)] = row.text(1).components(separatedBy: "\u{1F}")
            }
            let rollover = try db.rows("SELECT val FROM config WHERE key = 'rollover'").first.map { $0.blob(0) }
            rolloverHour = rollover.flatMap { Int(String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespaces)) }
        } else {
            guard let col = try db.rows("SELECT models, decks, conf FROM col").first else {
                throw Failure(description: "missing col table")
            }
            var types: [Int64: NoteType] = [:]
            if let models = try JSONSerialization.jsonObject(with: Data(col.text(0).utf8)) as? [String: [String: Any]] {
                for (key, model) in models {
                    guard let id = Int64(key) else { continue }
                    let flds = (model["flds"] as? [[String: Any]] ?? [])
                        .sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
                    types[id] = NoteType(name: model["name"] as? String ?? "", cloze: model["type"] as? Int == 1,
                                         fields: flds.map { $0["name"] as? String ?? "" },
                                         templates: (model["tmpls"] as? [Any])?.count ?? 0)
                }
            }
            noteTypes = types
            if let decks = try JSONSerialization.jsonObject(with: Data(col.text(1).utf8)) as? [String: [String: Any]] {
                for (key, deck) in decks {
                    if let id = Int64(key) { deckNames[id] = (deck["name"] as? String ?? "").components(separatedBy: "::") }
                }
            }
            let conf = try? JSONSerialization.jsonObject(with: Data(col.text(2).utf8)) as? [String: Any]
            rolloverHour = conf?["rollover"] as? Int
        }

        notes = try db.rows("SELECT id, mid, tags, flds FROM notes ORDER BY id").map { row in
            Note(id: row.int(0), typeID: row.int(1),
                 fields: row.text(3).components(separatedBy: "\u{1F}"),
                 tags: row.text(2).split(separator: " ").map(String.init))
        }
        cards = try db.rows("SELECT id, nid, did, odid, ord, type, queue, mod FROM cards ORDER BY id").map { row in
            let deck = row.int(3) != 0 ? row.int(3) : row.int(2)
            return Card(id: row.int(0), noteID: row.int(1), deck: deckNames[deck] ?? ["Default"],
                        ord: Int(row.int(4)), type: Int(row.int(5)), queue: Int(row.int(6)), modified: row.int(7))
        }
        reviews = try db.rows("SELECT id, cid, ease, ivl, lastIvl, time, type FROM revlog ORDER BY id").map { row in
            Review(id: row.int(0), cardID: row.int(1), ease: Int(row.int(2)), ivl: Int(row.int(3)),
                   lastIvl: Int(row.int(4)), time: Int(row.int(5)), type: Int(row.int(6)))
        }
    }
}

// MARK: - SQLite

/// 唯讀的 SQLite 連線（Core 的 `SQLiteDB` 是內部型別，這裡只需要查詢）
private final class ReadOnlyDB {
    private var handle: OpaquePointer?

    struct Row {
        fileprivate let values: [Any?]
        func int(_ i: Int) -> Int64 { values[i] as? Int64 ?? Int64(values[i] as? Double ?? 0) }
        func text(_ i: Int) -> String {
            if let s = values[i] as? String { return s }
            if let d = values[i] as? Data { return String(decoding: d, as: UTF8.self) }
            return ""
        }
        func blob(_ i: Int) -> Data {
            if let d = values[i] as? Data { return d }
            if let s = values[i] as? String { return Data(s.utf8) }
            return Data()
        }
    }

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw AnkiCollection.Failure(description: "open: " + String(cString: sqlite3_errmsg(handle)))
        }
        // Anki 的索引使用自訂的 `unicase` collation；沒有註冊時查詢這些資料表會失敗（no query solution）
        sqlite3_create_collation_v2(handle, "unicase", SQLITE_UTF8, nil, { _, length1, text1, length2, text2 in
            let a = String(decoding: UnsafeRawBufferPointer(start: text1, count: Int(length1)), as: UTF8.self)
            let b = String(decoding: UnsafeRawBufferPointer(start: text2, count: Int(length2)), as: UTF8.self)
            let x = a.lowercased(), y = b.lowercased()
            return x < y ? -1 : (x > y ? 1 : 0)
        }, nil)
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AnkiCollection.Failure(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw AnkiCollection.Failure(description: String(cString: sqlite3_errmsg(handle))) }
            var values: [Any?] = []
            for i in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: values.append(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT: values.append(sqlite3_column_double(statement, i))
                case SQLITE_TEXT: values.append(String(cString: sqlite3_column_text(statement, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    values.append(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, i), count: count))
                default: values.append(nil)
                }
            }
            result.append(Row(values: values))
        }
        return result
    }
}

// MARK: - Protobuf

/// 只讀需要的欄位：`notetypes.config` 的 kind、新格式 `media` 的 `MediaEntries`
enum Protobuf {
    struct Field {
        let number: Int
        /// wire type 0 的值
        let varint: UInt64?
        /// wire type 2 的內容
        let bytes: Data?
    }

    /// 逐欄位讀出；遇到不認得或損壞的資料就停止
    static func fields(_ data: Data) -> [Field] {
        var result: [Field] = []
        var p = data.startIndex
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while p < data.endIndex, shift < 64 {
                let byte = data[p]
                p += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while p < data.endIndex {
            guard let key = readVarint() else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return result }
                result.append(Field(number: number, varint: v, bytes: nil))
            case 1:
                guard data.endIndex - p >= 8 else { return result }
                p += 8
            case 2:
                guard let length = readVarint(), length <= UInt64(data.endIndex - p) else { return result }
                let end = p + Int(length)
                result.append(Field(number: number, varint: nil, bytes: data.subdata(in: p..<end)))
                p = end
            case 5:
                guard data.endIndex - p >= 4 else { return result }
                p += 4
            default:
                return result
            }
        }
        return result
    }

    static func varint(field: Int, in data: Data) -> UInt64? {
        fields(data).last { $0.number == field && $0.varint != nil }?.varint
    }
}
