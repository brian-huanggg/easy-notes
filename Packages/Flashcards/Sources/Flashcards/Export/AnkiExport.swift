import Foundation

/// 匯出給 Anki 的純文字檔（見 architecture/flashcards.md「互通」）。
///
/// 依筆記類型拆成三個檔，不寫筆記類型欄：Anki 內建類型的名稱隨介面語言不同（例如「基本型」），
/// 寫了對不上就匯入失敗，所以匯入時在 Anki 的對話框選類型。欄位順序與 Anki 內建類型相同。
public enum AnkiExport {
    public struct File: Equatable, Sendable {
        public let name: String
        public let text: String
        public let noteCount: Int
    }

    /// 檔名（不翻譯：Anki 使用者靠它對應筆記類型）
    static let fileNames: [CardType: String] = [ // l10n:fixed 匯出檔名
        .forward: "basic.txt",
        .bidirectional: "basic-and-reversed.txt",
        .cloze: "cloze.txt",
    ]

    /// `notes` 依路徑、行號排序後輸出；沒有卡片的類型不產生檔案。`tags`：路徑 → 筆記的標籤
    public static func files(_ notes: [(path: String, note: CardNote)], tags: [String: [String]]) -> [File] {
        let sorted = notes.filter { $0.note.id != nil }.sorted {
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame ? $0.note.line < $1.note.line : order == .orderedAscending
        }
        return [CardType.forward, .bidirectional, .cloze].compactMap { type in
            let rows = sorted.filter { $0.note.type == type }.map { row($0.note, path: $0.path, tags: tags[$0.path] ?? []) }
            guard !rows.isEmpty else { return nil }
            // guid、牌組、兩個欄位（Front / Back；克漏字為 Text / Back Extra）、標籤
            let header = ["#separator:tab", "#html:true", "#guid column:1", "#deck column:2", "#tags column:5"] // l10n:fixed Anki 檔頭
            let text = (header + rows.map { $0.map(field).joined(separator: "\t") }).joined(separator: "\n") + "\n"
            return File(name: fileNames[type]!, text: text, noteCount: rows.count)
        }
    }

    static func row(_ note: CardNote, path: String, tags: [String]) -> [String] {
        let fields: (String, String) = switch note.type {
        case .forward, .bidirectional: (html(note.front), html(note.back))
        case .cloze: (cloze(note.front), "")
        }
        return [note.id ?? "", deck(path), fields.0, fields.1, tags.map(tag).joined(separator: " ")]
    }

    /// 資料夾 `日文/N2` → Anki 牌組 `日文::N2`；Vault 根目錄為空白（Anki 改用匯入對話框選的牌組）
    static func deck(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent.split(separator: "/").joined(separator: "::")
    }

    /// Anki 的標籤以空白分隔、以 `::` 表示階層
    static func tag(_ tag: String) -> String {
        tag.split(whereSeparator: \.isWhitespace).joined(separator: "_").replacingOccurrences(of: "/", with: "::")
    }

    /// 克漏字：第 n 個 `{{}}` → `{{cn::…}}`，其餘文字轉成 HTML
    static func cloze(_ text: String) -> String {
        CardSyntax.clozeSegments(text).map { segment in
            guard let index = segment.cloze else { return html(segment.text) }
            return "{{c\(index + 1)::\(html(segment.text))}}"
        }
        .joined()
    }

    /// 含 `"`、tab 或換行時加上引號（雙引號重複一次），其餘原樣輸出
    static func field(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        guard flat.contains("\"") else { return flat }
        return "\"" + flat.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Markdown → HTML

    /// 行內 Markdown 轉成 Anki 的 HTML：粗體、斜體、刪除線、螢光、行內程式碼、連結、`[[連結]]`（只留顯示文字）。
    /// 行內程式碼中的內容不轉換
    static func html(_ markdown: String) -> String {
        let code = CardSyntax.codeSpans(in: markdown[...])
        var result = ""
        var last = markdown.startIndex
        for span in code {
            result += inline(String(markdown[last..<span.lowerBound]))
            let ticks = markdown[span].prefix { $0 == "`" }.count
            let content = markdown[span].dropFirst(ticks).dropLast(ticks).trimmingCharacters(in: .whitespaces)
            result += "<code>\(escape(content))</code>"
            last = span.upperBound
        }
        return result + inline(String(markdown[last...]))
    }

    private static func inline(_ text: String) -> String {
        var s = escape(text)
        s = s.replacing(/\[\[([^\]|]+)\|([^\]]+)\]\]/) { String($0.2) }
        s = s.replacing(/\[\[([^\]]+)\]\]/) { String($0.1) }
        s = s.replacing(/\[([^\]]+)\]\(([^)\s]+)\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        s = s.replacing(/\*\*(.+?)\*\*|__(.+?)__/) { "<b>\($0.1 ?? $0.2 ?? "")</b>" }
        s = s.replacing(/\*(.+?)\*/) { "<i>\($0.1)</i>" }
        s = s.replacing(/~~(.+?)~~/) { "<s>\($0.1)</s>" }
        s = s.replacing(/==(.+?)==/) { "<mark>\($0.1)</mark>" }
        return s
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
