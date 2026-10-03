import EasyNotesCore
import Foundation

/// 表格的顯示設定，存在旁檔 `<檔名>.csv.meta.json`（`.tsv` 相同）。
/// 只在使用者改了顯示設定時建立；檔案內容不受影響，沒有旁檔就是預設值。
public struct SheetMeta: Equatable, Sendable, Codable {
    public struct Column: Equatable, Sendable, Codable {
        /// 欄寬（pt）；nil = 預設寬度
        public var width: Double?

        public init(width: Double? = nil) {
            self.width = width
        }
    }

    public var version = 1
    /// 依欄位順序；比欄數少時，其餘欄位是預設值
    public var columns: [Column] = []
    /// 左側凍結的欄數
    public var frozenColumns = 0
    /// 第一列是標題（固定在上方、不參與排序與篩選）
    public var headerRow = true

    public init(columns: [Column] = [], frozenColumns: Int = 0, headerRow: Bool = true) {
        self.columns = columns
        self.frozenColumns = frozenColumns
        self.headerRow = headerRow
        normalize()
    }

    private enum Key: String, CodingKey {
        case version, columns, frozenColumns, headerRow
    }

    /// 欄位缺少時用預設值（手動編輯或舊版的旁檔也能讀）
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        columns = try c.decodeIfPresent([Column].self, forKey: .columns) ?? []
        let frozen = try c.decodeIfPresent(Int.self, forKey: .frozenColumns) ?? 0
        frozenColumns = max(0, frozen)
        headerRow = try c.decodeIfPresent(Bool.self, forKey: .headerRow) ?? true
        normalize()
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(SheetMeta.self, from: data)
    }

    public func data() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return ((try? encoder.encode(self)) ?? Data()) + Data([0x0A])
    }

    /// 與沒有旁檔時相同
    public var isDefault: Bool {
        columns.isEmpty && frozenColumns == 0 && headerRow
    }

    /// 去掉結尾的預設欄位，讓相同的設定有相同的位元組
    private mutating func normalize() {
        while columns.last?.width == nil, !columns.isEmpty { columns.removeLast() }
    }

    // MARK: 增刪欄（編輯器在檔案增刪欄時一起調整）

    public mutating func insertColumn(at index: Int) {
        if index < columns.count { columns.insert(Column(), at: index) }
        if index < frozenColumns { frozenColumns += 1 }
    }

    public mutating func deleteColumn(at index: Int) {
        if index < columns.count { columns.remove(at: index) }
        if index < frozenColumns { frozenColumns -= 1 }
        normalize()
    }

    // MARK: 合併

    /// 以欄位為單位的三方合併：只有一邊改的用那一邊，兩邊都改成不同值時本地優先。
    /// 沒有共同基準時以預設值為基準（兩邊各自建立旁檔：都保留對方改過、自己沒改的設定）
    public static func merge(base: SheetMeta?, local: SheetMeta, remote: SheetMeta) -> SheetMeta {
        let base = base ?? SheetMeta()
        func pick<T: Equatable>(_ b: T, _ l: T, _ r: T) -> T { l != b ? l : r }
        var merged = SheetMeta()
        merged.frozenColumns = pick(base.frozenColumns, local.frozenColumns, remote.frozenColumns)
        merged.headerRow = pick(base.headerRow, local.headerRow, remote.headerRow)
        let count = max(base.columns.count, local.columns.count, remote.columns.count)
        func width(_ meta: SheetMeta, _ i: Int) -> Double? { i < meta.columns.count ? meta.columns[i].width : nil }
        merged.columns = (0..<count).map { i in
            Column(width: pick(width(base, i), width(local, i), width(remote, i)))
        }
        merged.normalize()
        return merged
    }
}

/// `.csv.meta.json` / `.tsv.meta.json`：表格的顯示設定旁檔；Core 視它為主檔的伴隨檔
public protocol SheetMetaKind: DocumentKind {
    /// 主檔的副檔名（`csv` / `tsv`）
    static var sheetExtension: String { get }
}

public enum CSVMetaKind: SheetMetaKind {
    public static let id = "csv-meta"
    public static let fileExtensions = ["csv.meta.json"]
    public static let sheetExtension = "csv"
}

public enum TSVMetaKind: SheetMetaKind {
    public static let id = "tsv-meta"
    public static let fileExtensions = ["tsv.meta.json"]
    public static let sheetExtension = "tsv"
}

/// 主檔路徑加上這個後綴就是顯示設定旁檔
let sheetMetaSuffix = ".meta.json"

extension SheetMetaKind {
    public static func template(title: String) -> Data {
        SheetMeta().data()
    }

    public static func index(_ data: Data, fileName: String) -> IndexEntry {
        IndexEntry(title: (fileName as NSString).deletingPathExtension, plainText: "")
    }

    /// 去掉 `.meta.json` 就是主檔 `<檔名>.csv`
    public static func companionOf(_ path: String) -> String? {
        path.lowercased().hasSuffix("." + sheetExtension + sheetMetaSuffix)
            ? String(path.dropLast(sheetMetaSuffix.count)) : nil
    }

    /// 一邊不是合法的 JSON 就用另一邊；兩邊都不合法才交給衝突副本
    public static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        if local == remote { return local }
        switch (try? SheetMeta(data: local), try? SheetMeta(data: remote)) {
        case let (l?, r?):
            return SheetMeta.merge(base: base.flatMap { try? SheetMeta(data: $0) }, local: l, remote: r).data()
        case (_?, nil): return local
        case (nil, _?): return remote
        case (nil, nil): return nil
        }
    }
}
