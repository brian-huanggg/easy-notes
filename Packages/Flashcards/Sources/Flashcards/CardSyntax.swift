import Foundation

public enum CardType: String, Codable, Sendable {
    /// `問 :: 答`
    case forward
    /// `中文 ;; English`：正向、反向各一張
    case bidirectional
    /// `{{答案}}`：每個 `{{}}` 一張
    case cloze
}

/// md 中的一筆卡片 note（Anki 的 note）：一行，或首行加上子行的多行 note。一筆 note 依類型產生一或多張卡片。
public struct CardNote: Equatable, Codable, Sendable {
    /// 首行行尾的 `^id`（不含 `^`）；尚未補上時為 nil
    public var id: String?
    public var type: CardType
    /// 首行是第幾行（從 0 起算）
    public var line: Int
    /// 最後一行；單行 note 等於 `line`
    public var endLine: Int
    /// 正向 / 雙向：`::`、`;;` 左邊；克漏字：Text（保留 `{{}}`）。多行 note 以 `\n` 分行
    public var front: String
    /// 正向 / 雙向：右邊；克漏字：Back Extra（單行克漏字為空字串）
    public var back: String
    /// 克漏字的答案，依出現順序
    public var clozes: [String]

    public init(id: String?, type: CardType, line: Int, endLine: Int? = nil, front: String, back: String,
                clozes: [String] = []) {
        self.id = id
        self.type = type
        self.line = line
        self.endLine = endLine ?? line
        self.front = front
        self.back = back
        self.clozes = clozes
    }

    private enum CodingKeys: String, CodingKey { case id, type, line, endLine, front, back, clozes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        type = try c.decode(CardType.self, forKey: .type)
        line = try c.decode(Int.self, forKey: .line)
        endLine = try c.decodeIfPresent(Int.self, forKey: .endLine) ?? line
        front = try c.decode(String.self, forKey: .front)
        back = try c.decode(String.self, forKey: .back)
        clozes = try c.decode([String].self, forKey: .clozes)
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
/// - 清單項目以 ` ::` / ` ;;` 結尾時延伸成多行 note（`parseBlock`）
/// - 程式碼區塊、行內程式碼與 frontmatter 內不解析；公式（`$…$`、`$$…$$`）內的 `::`、`;;`、`{{}}` 不算
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
        let all = lines(text).map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var index = 0
        while index < all.count {
            let line = all[index]
            defer { index += 1 }
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
            if let parsed = parseBlock(all, at: index) {
                result.append(parsed)
                // 子行屬於這筆 note，不另外解析
                index = parsed.note.endLine
            } else if let parsed = parseLine(line, index: index) {
                result.append(parsed)
            }
        }
        return result
    }

    // MARK: 多行

    /// 多行 note：首行是清單項目、以 ` ::` 或 ` ;;` 結尾（`^id` 之前），內容 = 首行文字 + 清單項目的子行
    static func parseBlock(_ all: [String], at index: Int) -> ParsedLine? {
        let line = all[index]
        var body = line[...]
        var idRange: Range<Int>?
        var id: String?
        if let match = line.firstMatch(of: blockID) {
            id = String(match.1)
            let caret = line[match.range].firstIndex(of: "^")!
            idRange = line.distance(from: line.startIndex, to: caret)..<line.distance(from: line.startIndex, to: match.range.upperBound)
            body = line[..<match.range.lowerBound]
        }
        let content = String(body).trimmingTrailingWhitespace
        guard let item = content.prefixMatch(of: listItemPrefix) else { return nil }
        let text = content[item.range.upperBound...]
        guard text.count > 3, let type = trailingSeparator(text) else { return nil }
        let head = text.dropLast(2).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }

        // 子行：縮排達到清單文字起點的行（空行也算），結尾的空行不算
        let column = indentColumns(item.1) + item.2.count + min(item.3.count, 4)
        var end = index
        var j = index + 1
        while j < all.count {
            let child = all[j]
            if child.allSatisfy(\.isWhitespace) {
                j += 1
                continue
            }
            guard indentColumns(child.prefix { $0 == " " || $0 == "\t" }) >= column else { break }
            end = j
            j += 1
        }
        guard end > index else { return nil }
        // 去掉子行共同的縮排（至少到清單文字起點；tab 縮排的大綱會多出幾欄）
        let common = all[(index + 1)...end].filter { !$0.allSatisfy(\.isWhitespace) }
            .map { indentColumns($0.prefix { $0 == " " || $0 == "\t" }) }.min() ?? column
        let children = all[(index + 1)...end].map { dropColumns($0, common) }

        // 分界行：程式碼區塊外第一個只有 `::` 或 `;;` 的行
        let flags = fenceFlags(children)
        let divider = children.indices.first { !flags[$0] && ["::", ";;"].contains(children[$0].trimmingCharacters(in: .whitespaces)) }
        let cleaned = zip(children, flags).map { $1 ? $0 : stripBlockID($0) }
        let before = divider.map { Array(cleaned[..<$0]) } ?? cleaned
        let after = divider.map { Array(cleaned[($0 + 1)...]) } ?? []

        let textPart = trimBlankLines([head] + before).joined(separator: "\n")
        let answers = clozeAnswers(textPart)
        if !answers.isEmpty {
            guard answers.allSatisfy({ !$0.isEmpty }) else { return nil }
            let note = CardNote(id: id, type: .cloze, line: index, endLine: end, front: textPart,
                                back: trimBlankLines(after).joined(separator: "\n"), clozes: answers)
            return ParsedLine(note: note, content: content, idRange: idRange)
        }
        let front = divider == nil ? head : textPart
        let back = trimBlankLines(divider == nil ? cleaned : after).joined(separator: "\n")
        guard !back.isEmpty else { return nil }
        let note = CardNote(id: id, type: type, line: index, endLine: end, front: front, back: back)
        return ParsedLine(note: note, content: content, idRange: idRange)
    }

    /// 清單項目的開頭：縮排、符號、符號後的空白（不含引言、標題）
    private static var listItemPrefix: Regex<(Substring, Substring, Substring, Substring)> {
        /^([ \t]*)([-*+]|\d+[.)])([ \t]+)/
    }

    /// 行尾的 ` ::` / ` ;;`（不在公式與行內程式碼內）
    private static func trailingSeparator(_ text: Substring) -> CardType? {
        let symbol = text.suffix(2)
        guard symbol == "::" || symbol == ";;" else { return nil }
        let before = text.dropLast(2)
        guard let last = before.last, last.isWhitespace else { return nil }
        let code = codeSpans(in: text)
        let protected = code + mathSpans(in: text, code: code).map(\.range)
        let range = before.endIndex..<text.endIndex
        guard !protected.contains(where: { $0.overlaps(range) }) else { return nil }
        return symbol == "::" ? .forward : .bidirectional
    }

    /// 縮排的欄數（tab = 4 欄）
    static func indentColumns<S: StringProtocol>(_ whitespace: S) -> Int {
        whitespace.reduce(0) { $1 == "\t" ? $0 + 4 : $0 + 1 }
    }

    /// 去掉開頭的 `columns` 欄縮排；tab 跨過界線時補上空白
    static func dropColumns(_ line: String, _ columns: Int) -> String {
        var col = 0
        var i = line.startIndex
        while i < line.endIndex, col < columns {
            let char = line[i]
            guard char == " " || char == "\t" else { break }
            col += char == "\t" ? 4 : 1
            i = line.index(after: i)
        }
        let rest = String(line[i...])
        if rest.allSatisfy(\.isWhitespace) { return "" }
        return String(repeating: " ", count: max(0, col - columns)) + rest
    }

    /// 每一行是否在程式碼區塊內（含開頭、結尾的 ``` 行）；沒有關閉的程式碼區塊到結尾為止
    static func fenceFlags(_ lines: [String]) -> [Bool] {
        var fence: (char: Character, count: Int)?
        return lines.map { line in
            if let marker = fenceMarker(line) {
                if let open = fence {
                    if marker.char == open.char, marker.count >= open.count, marker.isBare { fence = nil }
                } else {
                    fence = (marker.char, marker.count)
                }
                return true
            }
            return fence != nil
        }
    }

    /// 子行行尾的 `^id` 不算，顯示時去掉
    private static func stripBlockID(_ line: String) -> String {
        guard let match = line.firstMatch(of: blockID) else { return line }
        return String(line[..<match.range.lowerBound]).trimmingTrailingWhitespace
    }

    private static func trimBlankLines(_ lines: [String]) -> [String] {
        var slice = lines[...]
        while let first = slice.first, first.isEmpty { slice = slice.dropFirst() }
        while let last = slice.last, last.isEmpty { slice = slice.dropLast() }
        return Array(slice)
    }

    /// 克漏字答案（去掉前後空白），依出現順序；逐行比對，程式碼區塊內不算
    static func clozeAnswers(_ text: String) -> [String] {
        clozeSegments(text).compactMap { $0.cloze == nil ? nil : $0.text }
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
        let math = mathSpans(in: text, code: code)
        let protected = code + math.map(\.range)
        let outsideProtected = { (range: Range<Substring.Index>) in
            !protected.contains { $0.overlaps(range) }
        }

        let clozes = clozeMatches(in: text, code: code, math: math)
        if !clozes.isEmpty {
            let answers = clozes.map { String($0.answer).trimmingCharacters(in: .whitespaces) }
            guard answers.allSatisfy({ !$0.isEmpty }) else { return nil }
            let note = CardNote(id: id, type: .cloze, line: index, front: String(text), back: "", clozes: answers)
            return ParsedLine(note: note, content: content, idRange: idRange)
        }

        guard let separator = separators(in: text).first(where: { outsideProtected($0.range) }) else { return nil }
        let front = text[..<separator.range.lowerBound].trimmingCharacters(in: .whitespaces)
        let back = text[separator.range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !front.isEmpty, !back.isEmpty else { return nil }
        let note = CardNote(id: id, type: separator.type, line: index, front: front, back: back)
        return ParsedLine(note: note, content: content, idRange: idRange)
    }

    /// 克漏字的一行切成片段：一般文字與第幾個 `{{}}`（從 0 起算，內容不含括號）。
    /// 與 `parseLine` 相同，行內程式碼與公式中的 `{{}}` 不算
    /// 多行內容逐行比對（行內程式碼與公式不跨行），程式碼區塊內不算；片段的文字保留 `\n`
    public static func clozeSegments(_ text: String) -> [(text: String, cloze: Int?)] {
        var result: [(String, Int?)] = []
        var pending = ""
        var index = 0
        let all = lines(text)
        let flags = fenceFlags(all)
        for (n, line) in all.enumerated() {
            if n > 0 { pending += "\n" }
            if flags[n] {
                pending += line
                continue
            }
            var last = line.startIndex
            for match in clozeMatches(in: line[...]) {
                pending += line[last..<match.range.lowerBound]
                if !pending.isEmpty { result.append((pending, nil)) }
                pending = ""
                result.append((String(match.answer).trimmingCharacters(in: .whitespaces), index))
                index += 1
                last = match.range.upperBound
            }
            pending += line[last...]
        }
        if !pending.isEmpty { result.append((pending, nil)) }
        return result
    }

    /// 前後有空白的 `::` 與 `;;`，依出現順序
    private static func separators(in text: Substring) -> [(range: Range<Substring.Index>, type: CardType)] {
        // Swift Regex 不支援 lookbehind：前面的空白算在比對內，範圍只取分隔符本身
        text.matches(of: /\s(::|;;)(?=\s)/).map { ($0.1.startIndex..<$0.1.endIndex, $0.1 == "::" ? .forward : .bidirectional) }
    }

    /// 克漏字 `{{答案}}`：答案至少一個字元、不含換行；`{{`、`}}` 在程式碼與公式之外；
    /// 答案中的 `{`、`}` 只能出現在公式或行內程式碼裡（`{{$\frac{a}{b}$}}`、``{{`a{b}`}}``）；程式碼要完整在答案內
    static func clozeMatches(in text: Substring) -> [(range: Range<Substring.Index>, answer: Substring)] {
        let code = codeSpans(in: text)
        return clozeMatches(in: text, code: code, math: mathSpans(in: text, code: code))
    }

    private static func clozeMatches(in text: Substring, code: [Range<Substring.Index>],
                                     math: [MathSpan]) -> [(range: Range<Substring.Index>, answer: Substring)] {
        let protected = code + math.map(\.range)
        var result: [(Range<Substring.Index>, Substring)] = []
        var i = text.startIndex
        while i < text.endIndex {
            if let span = protected.first(where: { $0.contains(i) }) {
                i = span.upperBound
                continue
            }
            guard text[i...].hasPrefix("{{") else {
                i = text.index(after: i)
                continue
            }
            let start = text.index(i, offsetBy: 2)
            var j = start
            var end: Substring.Index?
            while j < text.endIndex {
                if let span = math.first(where: { $0.range.lowerBound == j }) {
                    j = span.range.upperBound
                    continue
                }
                // `{{` 在程式碼之外，所以答案中遇到的程式碼都從答案內開始，整段跳過
                if let span = code.first(where: { $0.lowerBound == j }) {
                    j = span.upperBound
                    continue
                }
                let char = text[j]
                if char == "\n" || char == "{" { break }
                if char == "}" {
                    let next = text.index(after: j)
                    if j > start, next < text.endIndex, text[next] == "}" { end = j }
                    break
                }
                j = text.index(after: j)
            }
            guard let end else {
                i = text.index(after: i)
                continue
            }
            let upper = text.index(end, offsetBy: 2)
            result.append((i..<upper, text[start..<end]))
            i = upper
        }
        return result
    }

    /// 公式：`range` 含 `$`；`display` = `$$…$$`
    struct MathSpan: Equatable {
        var range: Range<Substring.Index>
        var display: Bool
        /// 不含 `$` 的 LaTeX
        var content: Range<Substring.Index>
    }

    /// 公式的範圍（同 Obsidian / Pandoc）：開頭的 `$` 後面不能是空白，結尾的 `$` 前面不能是空白、後面不能是數字；
    /// `$$…$$` 優先；`\` 後面的字元不當作分隔符；不在行內程式碼中，也不跨進程式碼
    static func mathSpans(in text: Substring, code: [Range<Substring.Index>]) -> [MathSpan] {
        var spans: [MathSpan] = []
        var i = text.startIndex
        while i < text.endIndex {
            if let span = code.first(where: { $0.contains(i) }) {
                i = span.upperBound
                continue
            }
            let char = text[i]
            if char == "\\" {
                i = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            guard char == "$" else {
                i = text.index(after: i)
                continue
            }
            // 公式不能跨進程式碼：結尾只找到下一段程式碼之前
            let limit = code.map(\.lowerBound).filter { $0 > i }.min() ?? text.endIndex
            let next = text.index(after: i)
            if next < limit, text[next] == "$" {
                let open = text.index(after: next)
                if let close = closingDollar(in: text, from: open, limit: limit, display: true),
                   !text[open..<close].allSatisfy(\.isWhitespace) {
                    let end = text.index(close, offsetBy: 2)
                    spans.append(MathSpan(range: i..<end, display: true, content: open..<close))
                    i = end
                } else {
                    i = open
                }
                continue
            }
            if next < limit, !text[next].isWhitespace,
               let close = closingDollar(in: text, from: next, limit: limit, display: false) {
                let end = text.index(after: close)
                spans.append(MathSpan(range: i..<end, display: false, content: next..<close))
                i = end
                continue
            }
            i = next
        }
        return spans
    }

    private static func closingDollar(in text: Substring, from start: Substring.Index, limit: Substring.Index,
                                      display: Bool) -> Substring.Index? {
        var j = start
        while j < limit {
            let char = text[j]
            if char == "\\" {
                j = text.index(j, offsetBy: 2, limitedBy: limit) ?? limit
                continue
            }
            if char == "$" {
                let next = text.index(after: j)
                if display {
                    if next < limit, text[next] == "$" { return j }
                } else if j > start, !text[text.index(before: j)].isWhitespace,
                          next == text.endIndex || !("0"..."9").contains(text[next]) {
                    return j
                }
            }
            j = text.index(after: j)
        }
        return nil
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
    static func fenceMarker(_ line: String) -> (char: Character, count: Int, isBare: Bool)? {
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
