import EasyNotesCore
import Foundation

/// 卡片文字的行內 Markdown 與公式，給複習畫面與卡片瀏覽顯示（見 architecture/flashcards.md「卡片內容」）。
///
/// 語法與 `AnkiExport.html` 相同：粗體、斜體、刪除線、螢光、行內程式碼、連結、`[[連結]]`（只留顯示文字），
/// 公式 `$…$`、`$$…$$`，`\$` 是字面上的 `$`。只負責解析，不碰 SwiftUI，渲染在 `CardText`。
public enum CardMarkup {
    public struct Style: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let strike = Style(rawValue: 1 << 2)
        public static let highlight = Style(rawValue: 1 << 3)
        public static let code = Style(rawValue: 1 << 4)
        /// 克漏字的答案或挖空處（`StudyCard.Segment.emphasized`）
        public static let cloze = Style(rawValue: 1 << 5)
    }

    public enum Inline: Equatable, Sendable {
        case text(String, Style = [], link: String? = nil)
        /// 行內公式（LaTeX，不含 `$`）
        case math(String, Style = [])
    }

    public enum Block: Equatable, Sendable {
        /// 段落；多行時文字中含 `\n`
        case paragraph([Inline])
        /// 獨立公式 `$$…$$`：自成一段、置中
        case math(String, Style = [])
        /// 清單項目：`level` 從 0 起算；`marker` 為 `•`、`1.` 等，nil = 項目內的續行
        case listItem(level: Int, marker: String?, [Inline])
        /// 程式碼區塊（不含 ``` 行），不解析 Markdown 與公式
        case code(String)
        /// `![[x.png]]`：Vault 相對路徑；`width` = `|300`
        case image(path: String, width: Double?)
        /// `![[x.mp3]]`：Vault 相對路徑（規則同圖片）
        case audio(path: String)
    }

    public static func blocks(_ text: String) -> [Block] {
        blocks([StudyCard.Segment(text)])
    }

    /// 多行內容切成區塊（見 architecture/flashcards.md「卡片內容」）；行內 Markdown 逐行解析
    public static func blocks(_ segments: [StudyCard.Segment]) -> [Block] {
        // 片段先接起來，克漏字前後的 Markdown（`**{{答案}}**`）才不會被切斷；強調的片段以私用字元標示。
        // 克漏字不跨行，所以標示在同一行內成對
        let joined = segments.map { $0.emphasized ? "\(Mark.cloze)\($0.text)\(Mark.cloze)" : $0.text }.joined()
        let lines = joined.components(separatedBy: "\n")
        let fences = CardSyntax.fenceFlags(lines)
        var result: [Block] = []
        var paragraph: [Inline] = []
        var indents: [Int] = []

        func endParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph)) }
            paragraph = []
        }
        /// 一行文字：圖片拆成獨立區塊，其餘交給 `emit`
        func split(_ text: String, emit: (String) -> Void) {
            var rest = text[...]
            while let match = rest.firstMatch(of: embed) {
                let before = rest[..<match.range.lowerBound]
                if !before.allSatisfy(\.isWhitespace) { emit(String(before)) }
                endParagraph()
                let path = Attachments.embedPath(String(match.1))
                if audioExtensions.contains((path as NSString).pathExtension.lowercased()) {
                    result.append(.audio(path: path))
                } else {
                    result.append(.image(path: path, width: match.2.flatMap { Double($0) }))
                }
                rest = rest[match.range.upperBound...]
            }
            if !rest.allSatisfy(\.isWhitespace) { emit(String(rest)) }
        }

        var n = 0
        while n < lines.count {
            let line = lines[n]
            if fences[n] {
                endParagraph()
                var code: [String] = []
                var m = n + 1
                while m < lines.count, fences[m], CardSyntax.fenceMarker(lines[m]) == nil {
                    code.append(lines[m])
                    m += 1
                }
                // 結尾的 ``` 行不算內容
                if m < lines.count, fences[m] { m += 1 }
                result.append(.code(code.joined(separator: "\n").filter { $0 != Mark.cloze }))
                n = m
                continue
            }
            n += 1
            if line.allSatisfy(\.isWhitespace) {
                endParagraph()
                continue
            }
            let indent = CardSyntax.indentColumns(line.prefix { $0 == " " || $0 == "\t" })
            if let item = line.wholeMatch(of: listItem) {
                endParagraph()
                while let top = indents.last, indent < top { indents.removeLast() }
                if indents.last.map({ indent > $0 }) ?? true { indents.append(indent) }
                let level = indents.count - 1
                var marker = String(item.2)
                if marker.first.map({ "-*+".contains($0) }) == true { marker = "•" }
                var content = String(item.3)
                if let task = content.prefixMatch(of: /\[([ xX])\]\s+/) {
                    marker = task.1 == " " ? "☐" : "☑" // l10n:fixed 待辦符號
                    content = String(content[task.range.upperBound...])
                }
                var first = true
                split(content) { text in
                    for block in inline(text) {
                        if case .paragraph(let inlines) = block {
                            result.append(.listItem(level: level, marker: first ? marker : nil, inlines))
                            first = false
                        } else {
                            result.append(block)
                        }
                    }
                }
                continue
            }
            if indent > 0, !indents.isEmpty {
                // 清單項目的續行
                endParagraph()
                let level = max(0, indents.filter { $0 < indent }.count - 1)
                split(line.trimmingCharacters(in: .whitespaces)) { text in
                    for block in inline(text) {
                        if case .paragraph(let inlines) = block {
                            result.append(.listItem(level: level, marker: nil, inlines))
                        } else {
                            result.append(block)
                        }
                    }
                }
                continue
            }
            if indent == 0 { indents = [] }
            split(line.trimmingCharacters(in: .whitespaces)) { text in
                for block in inline(text) {
                    if case .paragraph(let inlines) = block {
                        // 同一段落的行之間保留換行
                        if !paragraph.isEmpty { paragraph.append(.text("\n")) }
                        paragraph += inlines
                    } else {
                        endParagraph()
                        result.append(block)
                    }
                }
            }
        }
        endParagraph()
        return result.map(mergeTexts)
    }

    /// 一行的行內 Markdown 與公式（獨立公式拆成自己的區塊）
    static func inline(_ text: String) -> [Block] {
        let (masked, tokens) = mask(text)
        var builder = Builder(tokens: tokens)
        for node in markup(masked) { builder.add(node, style: [], link: nil) }
        return builder.finish()
    }

    /// 段落中相鄰而且樣式、連結相同的文字合併（行與行之間的 `\n` 接起來後）
    private static func mergeTexts(_ block: Block) -> Block {
        guard case .paragraph(let inlines) = block else { return block }
        var merged: [Inline] = []
        for inline in inlines {
            if case .text(let text, let style, let link) = inline,
               case .text(let previous, let lastStyle, let lastLink)? = merged.last, lastStyle == style, lastLink == link {
                merged[merged.count - 1] = .text(previous + text, style, link: link)
            } else {
                merged.append(inline)
            }
        }
        return .paragraph(merged)
    }

    private static var listItem: Regex<(Substring, Substring, Substring, Substring)> {
        /([ \t]*)([-*+]|\d+[.)])[ \t]+(.*)/
    }

    /// 卡片能播放的音檔副檔名
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "ogg", "flac"] // l10n:fixed

    /// `![[x.png]]`、`![[x.png|300]]`（副檔名同 `Attachments.imageExtensions`）或音檔 `![[x.mp3]]`
    static var embed: Regex<(Substring, Substring, Substring?)> {
        /!\[\[([^\[\]|\n]+\.(?i:png|jpe?g|gif|webp|heic|avif|mp3|m4a|wav|aac|ogg|flac))(?:\|(\d+)[^\[\]\n]*)?\]\]/
    }

    // MARK: 遮蔽程式碼與公式

    /// 私用區字元：不會出現在一般文字中，也不會被 Markdown 的正規表示式比對到
    enum Mark {
        static let cloze: Character = "\u{E000}"
        static let token: Character = "\u{E001}"
    }

    enum Token: Equatable {
        case code(String)
        case math(String, display: Bool)
        case dollar
    }

    /// 程式碼、公式與 `\$` 換成 `Mark.token`，內容依序放在 `tokens`
    static func mask(_ text: String) -> (String, [Token]) {
        let line = text[...]
        let code = CardSyntax.codeSpans(in: line)
        let math = CardSyntax.mathSpans(in: line, code: code)
        var spans: [(Range<Substring.Index>, Token)] = code.map { span in
            let ticks = line[span].prefix { $0 == "`" }.count
            return (span, .code(line[span].dropFirst(ticks).dropLast(ticks).trimmingCharacters(in: .whitespaces)))
        }
        spans += math.map { ($0.range, Token.math(String(line[$0.content]), display: $0.display)) }
        spans.sort { $0.0.lowerBound < $1.0.lowerBound }

        var masked = ""
        var tokens: [Token] = []
        var last = line.startIndex
        func plain(_ part: Substring) {
            // `\$` 以外的反斜線原樣保留
            var rest = part
            while let range = rest.range(of: "\\$") {
                masked += rest[..<range.lowerBound]
                masked.append(Mark.token)
                tokens.append(.dollar)
                rest = rest[range.upperBound...]
            }
            masked += rest
        }
        for (span, token) in spans {
            plain(line[last..<span.lowerBound])
            masked.append(Mark.token)
            tokens.append(token)
            last = span.upperBound
        }
        plain(line[last...])
        return (masked, tokens)
    }

    // MARK: 行內 Markdown

    indirect enum Node: Equatable {
        case text(String)
        /// 原樣顯示、不再套用後面的規則（圖片以外的 `![[x]]`）
        case literal(String)
        case styled(Style, [Node])
        case link(String, [Node])
    }

    /// 與 `AnkiExport.inline` 相同的順序依序套用；每條規則只作用在還沒被比對過的文字上
    static func markup(_ text: String) -> [Node] {
        var nodes: [Node] = [.text(text)]
        nodes = apply(nodes, /!\[\[[^\]]+\]\]/) { [.literal(String($0))] }
        nodes = apply(nodes, /\[\[([^\]|]+)\|([^\]]+)\]\]/) { [.text(String($0.2))] }
        nodes = apply(nodes, /\[\[([^\]]+)\]\]/) { [.text(String($0.1))] }
        nodes = apply(nodes, /\[([^\]]+)\]\(([^)\s]+)\)/) { [.link(String($0.2), [.text(String($0.1))])] }
        nodes = apply(nodes, /\*\*(.+?)\*\*|__(.+?)__/) { [.styled(.bold, [.text(String($0.1 ?? $0.2 ?? ""))])] }
        nodes = apply(nodes, /\*(.+?)\*/) { [.styled(.italic, [.text(String($0.1))])] }
        nodes = apply(nodes, /~~(.+?)~~/) { [.styled(.strike, [.text(String($0.1))])] }
        nodes = apply(nodes, /==(.+?)==/) { [.styled(.highlight, [.text(String($0.1))])] }
        return nodes
    }

    private static func apply<Output>(_ nodes: [Node], _ regex: Regex<Output>,
                                      _ replace: (Output) -> [Node]) -> [Node] {
        nodes.flatMap { node -> [Node] in
            switch node {
            case .styled(let style, let children): return [.styled(style, apply(children, regex, replace))]
            case .link(let url, let children): return [.link(url, apply(children, regex, replace))]
            case .literal: return [node]
            case .text(let text):
                var result: [Node] = []
                var last = text.startIndex
                for match in text.matches(of: regex) {
                    if last < match.range.lowerBound { result.append(.text(String(text[last..<match.range.lowerBound]))) }
                    result += replace(match.output)
                    last = match.range.upperBound
                }
                if last < text.endIndex { result.append(.text(String(text[last...]))) }
                return result
            }
        }
    }

    // MARK: 攤平成段落

    private struct Builder {
        var tokens: [Token]
        var blocks: [Block] = []
        var inlines: [Inline] = []
        /// 克漏字標記依出現順序開關
        var inCloze = false

        init(tokens: [Token]) {
            self.tokens = tokens.reversed()
        }

        mutating func add(_ node: Node, style: Style, link: String?) {
            switch node {
            case .styled(let added, let children):
                for child in children { add(child, style: style.union(added), link: link) }
            case .link(let url, let children):
                for child in children { add(child, style: style, link: url) }
            case .literal(let text):
                var run = text
                flush(&run, style, link)
            case .text(let text):
                var run = ""
                for char in text {
                    switch char {
                    case Mark.cloze:
                        flush(&run, style, link)
                        inCloze.toggle()
                    case Mark.token:
                        flush(&run, style, link)
                        let next = tokens.popLast()
                        token(next, style: current(style), link: link)
                    default:
                        run.append(char)
                    }
                }
                flush(&run, style, link)
            }
        }

        private func current(_ style: Style) -> Style {
            inCloze ? style.union(.cloze) : style
        }

        private mutating func flush(_ run: inout String, _ style: Style, _ link: String?) {
            guard !run.isEmpty else { return }
            append(.text(run, current(style), link: link))
            run = ""
        }

        private mutating func token(_ token: Token?, style: Style, link: String?) {
            switch token {
            case .code(let code): append(.text(code, style.union(.code), link: link))
            case .math(let latex, display: false): append(.math(latex, style))
            case .math(let latex, display: true):
                endParagraph()
                blocks.append(.math(latex, style.intersection(.cloze)))
            case .dollar: append(.text("$", style, link: link))
            case nil: break
            }
        }

        /// 相鄰而且樣式、連結相同的文字合併
        private mutating func append(_ inline: Inline) {
            if case .text(let text, let style, let link) = inline,
               case .text(let previous, let lastStyle, let lastLink)? = inlines.last, lastStyle == style, lastLink == link {
                inlines[inlines.count - 1] = .text(previous + text, style, link: link)
            } else {
                inlines.append(inline)
            }
        }

        /// 獨立公式前後的空白不留在段落中；只有空白的段落不輸出
        private mutating func endParagraph() {
            if case .text(let text, let style, let link)? = inlines.first {
                let trimmed = String(text.drop(while: \.isWhitespace))
                if trimmed.isEmpty { inlines.removeFirst() } else { inlines[0] = .text(trimmed, style, link: link) }
            }
            if case .text(let text, let style, let link)? = inlines.last {
                let trimmed = text.trimmingTrailingWhitespace
                if trimmed.isEmpty { inlines.removeLast() } else { inlines[inlines.count - 1] = .text(trimmed, style, link: link) }
            }
            if !inlines.isEmpty { blocks.append(.paragraph(inlines)) }
            inlines = []
        }

        mutating func finish() -> [Block] {
            endParagraph()
            return blocks
        }
    }
}
