import Foundation

/// CSV / TSV 的記憶體模型（RFC 4180）。保留原始位元組：未修改的記錄原樣寫回，
/// 修改過的記錄依檔案的風格（引號、換行符）重新產生，讓 diff 與合併保持乾淨。
/// 解析在位元組上做：分隔符、引號、換行都是 ASCII，UTF-8 與 Big5 的多位元組字元都不會落在這些值。
public struct SheetDocument: Sendable {
    public enum TextEncoding: Sendable, Equatable {
        case utf8
        /// 台灣 Excel 匯出常見（CP950）；唯讀，可轉成 UTF-8
        case big5
        /// 都不是：以 UTF-8 容錯顯示，唯讀
        case unknown
    }

    public enum LineEnding: Sendable, Equatable {
        case lf, crlf

        var bytes: Data { self == .lf ? Data([ASCII.lf]) : Data([ASCII.cr, ASCII.lf]) }
    }

    public struct Style: Sendable, Equatable {
        public var delimiter: UInt8
        /// 新增或修改的記錄用的換行符：檔案中多數記錄用的那一種
        public var lineEnding: LineEnding
        /// 每個欄位都加引號（否則只在必要時才加）
        public var quoteAll: Bool
        public var hasBOM: Bool
        public var trailingNewline: Bool

        public init(delimiter: UInt8, lineEnding: LineEnding = .lf, quoteAll: Bool = false,
                    hasBOM: Bool = false, trailingNewline: Bool = true) {
            self.delimiter = delimiter
            self.lineEnding = lineEnding
            self.quoteAll = quoteAll
            self.hasBOM = hasBOM
            self.trailingNewline = trailingNewline
        }
    }

    public struct Record: Sendable, Equatable {
        /// 穩定 row id：只在記憶體中，排序或篩選後仍能對回原本的列
        public let id: Int
        /// 欄數可能與其他列不同；顯示時補空格，未編輯就不寫回
        public internal(set) var fields: [String]
        /// 原始位元組（不含換行）；nil 代表已修改，寫回時重新產生
        var raw: Data?
        /// `\n`、`\r\n`；檔尾沒有換行的最後一筆為空
        var terminator: Data

        public var isModified: Bool { raw == nil }
    }

    public enum EditError: Error, Equatable {
        case readOnly
        case unknownRow(Int)
    }

    public private(set) var records: [Record]
    public private(set) var style: Style
    public let encoding: TextEncoding
    private var nextID: Int

    public var isEditable: Bool { encoding == .utf8 }
    /// 最寬的列的欄數
    public var columnCount: Int { records.reduce(0) { max($0, $1.fields.count) } }

    public init(data: Data, delimiter: UInt8) {
        var bytes = [UInt8](data)
        let hasBOM = bytes.starts(with: Self.bom)
        if hasBOM { bytes.removeFirst(Self.bom.count) }

        let encoding: TextEncoding
        if String(bytes: bytes, encoding: .utf8) != nil {
            encoding = .utf8
        } else if Self.big5(bytes) != nil {
            encoding = .big5
        } else {
            encoding = .unknown
        }
        self.encoding = encoding

        let scanned = Self.scan(bytes, delimiter: delimiter)
        records = scanned.enumerated().map { index, record in
            Record(id: index,
                   fields: record.fields.map { Self.decode($0, encoding) },
                   raw: Data(bytes[record.content]),
                   terminator: Data(bytes[record.content.upperBound..<record.end]))
        }
        nextID = records.count

        let crlfCount = records.filter { $0.terminator.count == 2 }.count
        let lfCount = records.filter { $0.terminator.count == 1 }.count
        let fields = scanned.filter { !$0.isBlank }.flatMap(\.quoted)
        style = Style(delimiter: delimiter,
                      lineEnding: crlfCount > lfCount ? .crlf : .lf,
                      quoteAll: !fields.isEmpty && !fields.contains(false),
                      hasBOM: hasBOM,
                      trailingNewline: records.last.map { !$0.terminator.isEmpty } ?? true)
    }

    /// 序列化：未修改的記錄逐位元組寫回
    public func data() -> Data {
        var out = style.hasBOM ? Data(Self.bom) : Data()
        for record in records {
            out += record.raw ?? Self.encode(record.fields, style: style)
            out += record.terminator
        }
        return out
    }

    // MARK: - 編輯（對應 Bridge 的 ops）

    public func index(ofRow id: Int) -> Int? {
        records.firstIndex { $0.id == id }
    }

    /// 改一個儲存格；超出該列欄數時只補到這一欄
    public mutating func setCell(row id: Int, column: Int, to value: String) throws(EditError) {
        try requireEditable()
        guard let i = index(ofRow: id) else { throw .unknownRow(id) }
        var fields = records[i].fields
        if column >= fields.count {
            guard !value.isEmpty else { return }
            fields += Array(repeating: "", count: column + 1 - fields.count)
        }
        guard fields[column] != value else { return }
        fields[column] = value
        update(i, fields: fields)
    }

    /// 在 `index` 插入列；`values` 的每一列不足目前欄數時補空字串。回傳新列的 id
    @discardableResult
    public mutating func insertRows(_ values: [[String]], at index: Int) throws(EditError) -> [Int] {
        try requireEditable()
        guard !values.isEmpty else { return [] }
        let width = columnCount
        let ending = style.lineEnding.bytes
        let atEnd = index >= records.count
        var new = values.map { row in
            defer { nextID += 1 }
            return Record(id: nextID, fields: row + Array(repeating: "", count: max(0, width - row.count)),
                          raw: nil, terminator: ending)
        }
        // 附加在沒有檔尾換行的最後一筆之後：原本的最後一筆補上換行，新的最後一筆保持沒有換行
        if atEnd, let last = records.indices.last, records[last].terminator.isEmpty {
            records[last].terminator = ending
            new[new.count - 1].terminator = Data()
        } else if atEnd, records.isEmpty, !style.trailingNewline {
            new[new.count - 1].terminator = Data()
        }
        records.insert(contentsOf: new, at: min(index, records.count))
        return new.map(\.id)
    }

    public mutating func deleteRows(_ ids: [Int]) throws(EditError) {
        try requireEditable()
        let remove = Set(ids)
        let lastHadNoNewline = records.last?.terminator.isEmpty == true
        records.removeAll { remove.contains($0.id) }
        if lastHadNoNewline, let last = records.indices.last {
            records[last].terminator = Data()
        }
    }

    /// 在第 `column` 欄之前插入空欄。最寬的列一定插入（含附加在最後）；
    /// 較短的列只在該欄落在列內時插入，不補尾端空欄；空白行不變
    public mutating func insertColumn(at column: Int) throws(EditError) {
        try requireEditable()
        let width = columnCount
        for i in records.indices where !isBlank(records[i])
            && (records[i].fields.count > column || records[i].fields.count == width) {
            var fields = records[i].fields
            fields.insert("", at: column)
            update(i, fields: fields)
        }
    }

    /// 刪掉唯一一欄的列變成空白行
    public mutating func deleteColumn(at column: Int) throws(EditError) {
        try requireEditable()
        for i in records.indices where records[i].fields.count > column && !isBlank(records[i]) {
            var fields = records[i].fields
            fields.remove(at: column)
            update(i, fields: fields.isEmpty ? [""] : fields)
        }
    }

    /// 改寫儲存格中的 `[[連結]]`；回傳是否有改
    mutating func replaceInCells(_ transform: (String) -> String) -> Bool {
        var changed = false
        for i in records.indices {
            let fields = records[i].fields.map(transform)
            if fields != records[i].fields {
                update(i, fields: fields)
                changed = true
            }
        }
        return changed
    }

    private mutating func update(_ i: Int, fields: [String]) {
        records[i].fields = fields
        records[i].raw = nil
    }

    private func isBlank(_ record: Record) -> Bool {
        record.fields == [""]
    }

    private func requireEditable() throws(EditError) {
        guard isEditable else { throw .readOnly }
    }

    // MARK: - 編碼

    /// Big5（CP950）轉成 UTF-8（不加 BOM），風格的其餘部分不變；其他編碼回傳 nil
    public static func convertToUTF8(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        if bytes.starts(with: bom) { bytes.removeFirst(bom.count) }
        if String(bytes: bytes, encoding: .utf8) != nil { return nil }
        return big5(bytes).map { Data($0.utf8) }
    }

    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    static let big5Encoding: String.Encoding? = {
        #if canImport(Darwin)
        // CP950：Big5 加上微軟的擴充字，台灣 Excel 匯出用這個
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue)))
        #else
        nil
        #endif
    }()

    static func big5(_ bytes: [UInt8]) -> String? {
        guard let big5Encoding, !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: big5Encoding)
    }

    static func decode(_ bytes: [UInt8], _ encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8, .unknown: String(decoding: bytes, as: UTF8.self)
        case .big5: big5(bytes) ?? String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - RFC 4180

    struct ScannedRecord {
        /// 不含換行的範圍；`end` 含換行
        var content: Range<Int>
        var end: Int
        var fields: [[UInt8]]
        var quoted: [Bool]

        var isBlank: Bool { content.isEmpty }
    }

    /// 寬鬆解析：引號只在欄位開頭才有意義；未關閉的引號延伸到檔尾；
    /// 結尾引號後面的字元原樣接在欄位後。換行接受 LF 與 CRLF，單獨的 CR 是內容。
    static func scan(_ b: [UInt8], from start: Int = 0, delimiter: UInt8) -> [ScannedRecord] {
        var records: [ScannedRecord] = []
        var i = start
        let n = b.count
        while i < n {
            let recordStart = i
            var fields: [[UInt8]] = [], quoted: [Bool] = []
            var field: [UInt8] = [], isQuoted = false
            var inQuotes = false, atFieldStart = true
            var contentEnd = n, end = n
            while i < n {
                let c = b[i]
                if inQuotes {
                    if c == ASCII.quote {
                        if i + 1 < n, b[i + 1] == ASCII.quote {
                            field.append(ASCII.quote)
                            i += 2
                        } else {
                            inQuotes = false
                            i += 1
                        }
                    } else {
                        field.append(c)
                        i += 1
                    }
                } else if c == ASCII.quote, atFieldStart {
                    inQuotes = true
                    isQuoted = true
                    atFieldStart = false
                    i += 1
                } else if c == delimiter {
                    fields.append(field); quoted.append(isQuoted)
                    field = []; isQuoted = false; atFieldStart = true
                    i += 1
                } else if c == ASCII.lf {
                    contentEnd = i; end = i + 1
                    break
                } else if c == ASCII.cr, i + 1 < n, b[i + 1] == ASCII.lf {
                    contentEnd = i; end = i + 2
                    break
                } else {
                    field.append(c)
                    atFieldStart = false
                    i += 1
                }
            }
            fields.append(field); quoted.append(isQuoted)
            records.append(ScannedRecord(content: recordStart..<contentEnd, end: end, fields: fields, quoted: quoted))
            i = end
        }
        return records
    }

    /// 依風格產生一筆記錄（不含換行）
    static func encode(_ fields: [String], style: Style) -> Data {
        var out = Data()
        for (i, field) in fields.enumerated() {
            if i > 0 { out.append(style.delimiter) }
            let bytes = Array(field.utf8)
            let needsQuotes = style.quoteAll
                || bytes.contains { $0 == style.delimiter || $0 == ASCII.quote || $0 == ASCII.lf || $0 == ASCII.cr }
            if needsQuotes {
                out.append(ASCII.quote)
                for c in bytes {
                    out.append(c)
                    if c == ASCII.quote { out.append(ASCII.quote) }
                }
                out.append(ASCII.quote)
            } else {
                out += bytes
            }
        }
        return out
    }
}

enum ASCII {
    static let quote: UInt8 = 0x22
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
}
