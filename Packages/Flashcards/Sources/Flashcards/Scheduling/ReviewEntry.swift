import Foundation

/// 四個作答按鈕（Anki 的 ease）
public enum Grade: Int, Codable, Sendable, CaseIterable {
    case again = 1, hard, good, easy
}

/// `.easynotes/srs/<deviceId>.jsonl` 的一行。欄位名稱與意義照 Anki 的 `revlog`，另加 `op`。
public struct ReviewEntry: Codable, Equatable, Hashable, Sendable {
    /// Anki revlog 的 `type`：複習當下的狀態
    public enum Kind: Int, Codable, Sendable {
        /// 新卡與 learning steps
        case learning = 0
        case review = 1
        case relearning = 2
        /// 手動事件（`op`）
        case manual = 4
    }

    /// 手動事件；未知的值在讀取時略過
    public enum Op: String, Codable, Sendable {
        case suspend, unsuspend, reset
    }

    /// 複習時間（Unix 毫秒）
    public var id: Int64
    /// 卡片 id（`^id` + 後綴）
    public var cid: String
    /// 1–4 = `Grade`；手動事件為 0
    public var ease: Int
    /// 這次的間隔：正數 = 天，負數 = 秒（learning / relearning steps）
    public var ivl: Int
    public var lastIvl: Int
    /// 作答花費的毫秒
    public var time: Int
    public var type: Kind
    public var op: Op?

    public init(id: Int64, cid: String, ease: Int, ivl: Int, lastIvl: Int, time: Int, type: Kind, op: Op? = nil) {
        self.id = id
        self.cid = cid
        self.ease = ease
        self.ivl = ivl
        self.lastIvl = lastIvl
        self.time = time
        self.type = type
        self.op = op
    }

    public static func manual(_ op: Op, cid: String, at date: Date) -> ReviewEntry {
        ReviewEntry(id: date.millis, cid: cid, ease: 0, ivl: 0, lastIvl: 0, time: 0, type: .manual, op: op)
    }

    public var grade: Grade? { type == .manual ? nil : Grade(rawValue: ease) }
    public var date: Date { Date(timeIntervalSince1970: Double(id) / 1000) }

    /// 一行 JSON（鍵依字母排序，不含換行）
    public var line: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }

    /// 損壞的行、未知的 `type` 或 `op`、`ease` 超出範圍時回傳 nil
    public init?(line: Substring) {
        guard let entry = try? JSONDecoder().decode(ReviewEntry.self, from: Data(line.utf8)) else { return nil }
        switch entry.type {
        case .manual: guard entry.op != nil else { return nil }
        default: guard entry.grade != nil else { return nil }
        }
        self = entry
    }

    enum CodingKeys: String, CodingKey {
        case id, cid, ease, ivl, lastIvl, time, type, op
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        cid = try c.decode(String.self, forKey: .cid)
        ease = try c.decode(Int.self, forKey: .ease)
        ivl = try c.decodeIfPresent(Int.self, forKey: .ivl) ?? 0
        lastIvl = try c.decodeIfPresent(Int.self, forKey: .lastIvl) ?? 0
        time = try c.decodeIfPresent(Int.self, forKey: .time) ?? 0
        type = try c.decode(Kind.self, forKey: .type)
        op = try c.decodeIfPresent(Op.self, forKey: .op)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(cid, forKey: .cid)
        try c.encode(ease, forKey: .ease)
        try c.encode(ivl, forKey: .ivl)
        try c.encode(lastIvl, forKey: .lastIvl)
        try c.encode(time, forKey: .time)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(op, forKey: .op)
    }
}

extension Date {
    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
