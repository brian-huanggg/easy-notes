import Foundation

/// 最小的 YAML frontmatter 處理：只讀頂層的純量與清單（`pinned`、`icon`、`tags`），
/// 寫入時只改動目標那一行，其餘內容逐位元組保留。不認識的欄位與格式一律原樣不動。
struct Frontmatter {
    /// frontmatter 區塊（含兩條 `---`）在原文中的範圍；nil = 沒有 frontmatter
    let range: Range<String.Index>?
    /// 區塊內、兩條 `---` 之間的各行（不含換行符）
    let lines: [Substring]
    /// 檔案使用的換行符（`\n` 或 `\r\n`）
    let newline: String

    init(_ text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        let open = "---" + newline
        let close = newline + "---"
        guard text.hasPrefix(open),
              let end = text.range(of: close, range: text.index(text.startIndex, offsetBy: open.count - newline.count)..<text.endIndex)
        else {
            range = nil
            lines = []
            return
        }
        // 結尾的 `---` 必須獨占一行
        var upper = end.upperBound
        if text[upper...].hasPrefix(newline) {
            upper = text.index(upper, offsetBy: newline.count)
        } else if upper != text.endIndex {
            range = nil
            lines = []
            return
        }
        range = text.startIndex..<upper
        let innerStart = text.index(text.startIndex, offsetBy: open.count)
        let inner = innerStart < end.lowerBound ? text[innerStart..<end.lowerBound] : ""
        lines = inner.isEmpty ? [] : inner.split(separator: newline, omittingEmptySubsequences: false)
            .map { Substring($0) }
    }

    /// 去掉 frontmatter 後的內文
    static func body(of text: String) -> Substring {
        let fm = Frontmatter(text)
        return fm.range.map { text[$0.upperBound...] } ?? text[...]
    }

    // MARK: 讀取

    /// 頂層純量欄位的值（去掉引號）；清單或不存在時回傳 nil
    func scalar(_ key: String) -> String? {
        guard let index = lineIndex(of: key) else { return nil }
        let value = Self.value(of: lines[index])
        return value.isEmpty ? nil : Self.unquote(value)
    }

    func bool(_ key: String) -> Bool {
        guard let value = scalar(key)?.lowercased() else { return false }
        return ["true", "yes", "on"].contains(value)
    }

    /// `tags: [a, b]`、`tags: a` 或下一行起的 `- a` 清單
    func list(_ key: String) -> [String] {
        guard let index = lineIndex(of: key) else { return [] }
        let value = Self.value(of: lines[index])
        if value.hasPrefix("[") && value.hasSuffix("]") {
            return value.dropFirst().dropLast().split(separator: ",").map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }
        if !value.isEmpty { return [Self.unquote(value)] }
        var items: [String] = []
        for line in lines[(index + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { break }
            items.append(Self.unquote(trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)))
        }
        return items.filter { !$0.isEmpty }
    }

    // MARK: 寫入

    /// 設定（`value` 非 nil）或移除頂層欄位，回傳新的全文。
    /// 沒有 frontmatter 時新增一個；移除後 frontmatter 變空就整個刪掉，讓「設定再移除」回到原本的位元組。
    func setting(_ key: String, to value: String?, in text: String) -> String {
        var newLines = lines.map(String.init)
        if let index = lineIndex(of: key) {
            if let value { newLines[index] = "\(key): \(value)" } else { newLines.remove(at: index) }
        } else if let value {
            newLines.append("\(key): \(value)")
        } else {
            return text
        }
        let rest = range.map { String(text[$0.upperBound...]) } ?? text
        guard !newLines.isEmpty else { return rest }
        return "---" + newline + newLines.joined(separator: newline) + newline + "---" + newline + rest
    }

    // MARK: 工具

    private func lineIndex(of key: String) -> Int? {
        lines.firstIndex { line in
            guard line.hasPrefix(key) else { return false }
            return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix(":")
        }
    }

    private static func value(of line: Substring) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // 行尾註解（不在引號內的 ` #`）
        if !value.hasPrefix("\""), !value.hasPrefix("'"), let hash = value.range(of: " #") {
            value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
