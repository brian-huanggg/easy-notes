import Foundation

public enum CardType: String, Codable, Sendable {
    /// `問 :: 答`
    case forward
    /// `中文 ;; English`：正向、反向各一張
    case bidirectional
    /// `{{答案}}`：每個 `{{}}` 一張
    case cloze
}

/// md 中的一行卡片（Anki 的 note）。一筆 note 依類型產生一或多張卡片。
public struct CardNote: Equatable, Codable, Sendable {
    /// 行尾的 `^id`（不含 `^`）；尚未補上時為 nil
    public var id: String?
    public var type: CardType
    /// 第幾行（從 0 起算）
    public var line: Int
    /// 正向 / 雙向：`::`、`;;` 左邊；克漏字：整行內容（保留 `{{}}`）
    public var front: String
    /// 正向 / 雙向：右邊；克漏字：空字串
    public var back: String
    /// 克漏字的答案，依出現順序
    public var clozes: [String]

    public init(id: String?, type: CardType, line: Int, front: String, back: String, clozes: [String] = []) {
        self.id = id
        self.type = type
        self.line = line
        self.front = front
        self.back = back
        self.clozes = clozes
    }

    /// 這筆 note 產生的卡片 id：正向 `c-x`；雙向再加反向 `c-x:r`；克漏字 `c-x:1`、`c-x:2`…
    public var cardIDs: [String] {
        guard let id else { return [] }
        switch type {
        case .forward: return [id]
        case .bidirectional: return [id, id + ":r"]
        case .cloze: return clozes.indices.map { "\(id):\($0 + 1)" }
        }
    }
}

/// 卡片語法（Vault 的 Markdown 方言）。web/src/markdown/cards.ts 的語法標示依同一套規則實作。
///
/// - 一行一筆 note；`::`、`;;` 前後要有空白；有 `{{}}` 的行一律是克漏字
/// - 程式碼區塊、行內程式碼與 frontmatter 內不解析
/// - 行首的清單、待辦、標題、引言標記不算在正面文字內
/// - 行尾的 `^id` 是 note 的身分（沿用 Obsidian 的 block id 語法）
public enum CardSyntax {
    public static func parse(_ text: String) -> [CardNote] {
        parseLines(text).map(\.note)
    }

    /// 解析結果附上 `^id` 在該行中的位置，補 id 時使用
    struct ParsedLine {
        var note: CardNote
        /// 去掉 `^id` 之後的行內容（不含行尾空白），id 由它的 hash 產生
        var content: String
        /// `^id`（含 `^`）在該行的範圍（以字元計，不含 `\r`）；沒有 id 時為 nil
        var idRange: Range<Int>?
    }

    static func parseLines(_ text: String) -> [ParsedLine] {
        var result: [ParsedLine] = []
        var fence: (char: Character, count: Int)?
        var inFrontmatter = false
        for (index, raw) in lines(text).enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if index == 0, line == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter {
                if line == "---" { inFrontmatter = false }
                continue
            }
            if let marker = fenceMarker(line) {
                if let open = fence {
                    if marker.char == open.char, marker.count >= open.count, marker.isBare { fence = nil }
                } else {
                    fence = (marker.char, marker.count)
                }
                continue
            }
            if fence != nil { continue }
            if let parsed = parseLine(line, index: index) { result.append(parsed) }
        }
        return result
    }

    /// 依 `\n` 切行，保留空行與 `\r`；`lines(x).joined(separator: "\n") == x`。
    /// 不能用 `split(separator: "\n")`：Swift 把 `\r\n` 當成一個 Character，CRLF 的行會切不開
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    // MARK: 單行

    // Regex 不是 Sendable，不能放在 static let
    private static var blockID: Regex<(Substring, Substring)> { /\s\^([A-Za-z0-9-]+)\s*$/ }
    private static var linePrefix: Regex<Substring> { /^\s*(?:>\s?)*\s*(?:#{1,6}\s+|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)?/ }
    private static var clozePattern: Regex<(Substring, Substring)> { /\{\{([^{}\n]+?)\}\}/ }

    static func parseLine(_ line: String, index: Int) -> ParsedLine? {
        var body = line[...]
        var idRange: Range<Int>?
        var id: String?
        if let match = line.firstMatch(of: blockID) {
            id = String(match.1)
            // 範圍從 `^` 開始（前面的空白留在內容中）
            let caret = line[match.range].firstIndex(of: "^")!
            idRange = line.distance(from: line.startIndex, to: caret)..<line.distance(from: line.startIndex, to: match.range.upperBound)
            body = line[..<match.range.lowerBound]
        }
        let content = String(body).trimmingTrailingWhitespace
        let prefixEnd = content.prefixMatch(of: linePrefix)?.range.upperBound ?? content.startIndex
        let text = content[prefixEnd...]
        let code = codeSpans(in: text)
        let outsideCode = { (range: Range<Substring.Index>) in
            !code.contains { $0.overlaps(range) }
        }

        let clozes = text.matches(of: clozePattern).filter { outsideCode($0.range) }
        if !clozes.isEmpty {
            let answers = clozes.map { String($0.1).trimmingCharacters(in: .whitespaces) }
            guard answers.allSatisfy({ !$0.isEmpty }) else { return nil }
            let note = CardNote(id: id, type: .cloze, line: index, front: String(text), back: "", clozes: answers)
            return ParsedLine(note: note, content: content, idRange: idRange)
        }

        guard let separator = separators(in: text).first(where: { outsideCode($0.range) }) else { return nil }
        let front = text[..<separator.range.lowerBound].trimmingCharacters(in: .whitespaces)
        let back = text[separator.range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !front.isEmpty, !back.isEmpty else { return nil }
        let note = CardNote(id: id, type: separator.type, line: index, front: front, back: back)
        return ParsedLine(note: note, content: content, idRange: idRange)
    }

    /// 克漏字的一行切成片段：一般文字與第幾個 `{{}}`（從 0 起算，內容不含括號）。
    /// 與 `parseLine` 相同，行內程式碼中的 `{{}}` 不算
    public static func clozeSegments(_ text: String) -> [(text: String, cloze: Int?)] {
        let code = codeSpans(in: text[...])
        var result: [(String, Int?)] = []
        var last = text.startIndex
        var index = 0
        for match in text.matches(of: clozePattern) where !code.contains(where: { $0.overlaps(match.range) }) {
            if last < match.range.lowerBound { result.append((String(text[last..<match.range.lowerBound]), nil)) }
            result.append((String(match.1).trimmingCharacters(in: .whitespaces), index))
            index += 1
            last = match.range.upperBound
        }
        if last < text.endIndex { result.append((String(text[last...]), nil)) }
        return result
    }

    /// 前後有空白的 `::` 與 `;;`，依出現順序
    private static func separators(in text: Substring) -> [(range: Range<Substring.Index>, type: CardType)] {
        // Swift Regex 不支援 lookbehind：前面的空白算在比對內，範圍只取分隔符本身
        text.matches(of: /\s(::|;;)(?=\s)/).map { ($0.1.startIndex..<$0.1.endIndex, $0.1 == "::" ? .forward : .bidirectional) }
    }

    /// 行內程式碼的範圍：成對且長度相同的反引號
    static func codeSpans(in text: Substring) -> [Range<Substring.Index>] {
        var spans: [Range<Substring.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "`" else {
                i = text.index(after: i)
                continue
            }
            var runEnd = i
            while runEnd < text.endIndex, text[runEnd] == "`" { runEnd = text.index(after: runEnd) }
            let run = text.distance(from: i, to: runEnd)
            var j = runEnd
            var closed = false
            while j < text.endIndex {
                guard text[j] == "`" else {
                    j = text.index(after: j)
                    continue
                }
                var k = j
                while k < text.endIndex, text[k] == "`" { k = text.index(after: k) }
                if text.distance(from: j, to: k) == run {
                    spans.append(i..<k)
                    i = k
                    closed = true
                    break
                }
                j = k
            }
            if !closed { i = runEnd }
        }
        return spans
    }

    /// ``` 或 ~~~ 開頭的行（前面可以有縮排）；`isBare` = 後面沒有語言標示，才能當結尾
    private static func fenceMarker(_ line: String) -> (char: Character, count: Int, isBare: Bool)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let rest = trimmed.dropFirst(count)
        if first == "`", rest.contains("`") { return nil }
        return (first, count, rest.allSatisfy(\.isWhitespace))
    }
}

extension String {
    var trimmingTrailingWhitespace: String {
        var s = self[...]
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
