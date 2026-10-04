import EasyNotesCore
import Foundation

/// `.csv` 與 `.tsv` 共用的行為，只差分隔符
public protocol SheetKind: DocumentKind {
    static var delimiter: UInt8 { get }
    /// 摘要開頭的類型名稱，例如「CSV」
    static var label: String { get }
}

public enum CSVKind: SheetKind {
    public static let id = "csv"
    public static let fileExtensions = ["csv"]
    public static let delimiter: UInt8 = 0x2C
    public static let label = "CSV"
}

public enum TSVKind: SheetKind {
    public static let id = "tsv"
    public static let fileExtensions = ["tsv"]
    public static let delimiter: UInt8 = 0x09
    public static let label = "TSV"
}

/// 索引的 `plainText` 上限（字元數），避免巨大的表格拖慢 FTS
let plainTextLimit = 100_000

extension SheetKind {
    /// 只有一列標題
    public static func template(title: String) -> Data {
        SheetDocument.encode([L("名稱"), L("備註")], style: .init(delimiter: delimiter)) + Data([ASCII.lf])
    }

    public static func index(_ data: Data, fileName: String) -> IndexEntry {
        let sheet = SheetDocument(data: data, delimiter: delimiter)
        var text = ""
        var length = 0
        var links: [String] = []
        var seen = Set<String>()
        for record in sheet.records {
            for field in record.fields where field.contains("[[") {
                for link in wikiLinks(in: field) where seen.insert(link).inserted { links.append(link) }
            }
            guard length < plainTextLimit else { continue }
            let line = record.fields.joined(separator: " ") + "\n"
            text += line
            length += line.count
        }
        let rows = sheet.records.count.formatted(.number)
        let columns = sheet.columnCount.formatted(.number)
        return IndexEntry(
            title: (fileName as NSString).deletingPathExtension,
            plainText: String(text.prefix(plainTextLimit)),
            links: links,
            summary: L("\(label) · \(rows) 列 · \(columns) 欄")
        )
    }

    /// 沒有共同基準（兩台裝置各自新建同名檔）時只接受完全相同的內容
    public static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        guard let base else { return local == remote ? local : nil }
        return SheetDocument.merge(base: base, local: local, remote: remote, delimiter: delimiter)
    }

    /// 儲存格中的 `[[舊名]]` / `[[舊名|別名]]` / `![[舊名]]`；只重寫有改到的記錄，唯讀的檔案不改
    public static func renameLinks(in data: Data, from oldName: String, to newName: String) -> Data? {
        var sheet = SheetDocument(data: data, delimiter: delimiter)
        guard sheet.isEditable else { return nil }
        let pattern = #"(!?\[\[)"# + NSRegularExpression.escapedPattern(for: oldName) + #"((?:\|[^\[\]\n]*)?\]\])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let template = "$1" + NSRegularExpression.escapedTemplate(for: newName) + "$2"
        let changed = sheet.replaceInCells { cell in
            guard cell.contains("[[") else { return cell }
            return regex.stringByReplacingMatches(in: cell, range: NSRange(cell.startIndex..., in: cell), withTemplate: template)
        }
        return changed ? sheet.data() : nil
    }

    static func wikiLinks(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n|]+)(?:\|[^\[\]\n]*)?\]\]"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }
}
