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
        case paragraph([Inline])
        /// 獨立公式 `$$…$$`：自成一段、置中
        case math(String, Style = [])
    }

    public static func blocks(_ text: String) -> [Block] {
        blocks([StudyCard.Segment(text)])
    }

    public static func blocks(_ segments: [StudyCard.Segment]) -> [Block] {
        // 片段接成一行再解析，克漏字前後的 Markdown（`**{{答案}}**`）才不會被切斷；強調的片段以私用字元標示
        let joined = segments.map { $0.emphasized ? "\(Mark.cloze)\($0.text)\(Mark.cloze)" : $0.text }.joined()
        let (masked, tokens) = mask(joined)
        var builder = Builder(tokens: tokens)
        for node in markup(masked) { builder.add(node, style: [], link: nil) }
        return builder.finish()
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
        case styled(Style, [Node])
        case link(String, [Node])
    }

    /// 與 `AnkiExport.inline` 相同的順序依序套用；每條規則只作用在還沒被比對過的文字上
    static func markup(_ text: String) -> [Node] {
        var nodes: [Node] = [.text(text)]
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
