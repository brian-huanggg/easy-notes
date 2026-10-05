import Foundation

/// Anki 欄位的 HTML → 卡片的 Markdown（見 architecture/flashcards.md「Anki 匯入」的「HTML → Markdown」）。
/// 不是完整的 HTML parser：只認得 Anki 編輯器會產生的標籤，其他標籤去掉、只留文字
enum AnkiHTML {
    struct Result: Equatable {
        var markdown: String
        /// 引用的媒體檔名（`<img src>`、`[sound:]`），依出現順序
        var media: [String]
    }

    static func markdown(_ html: String) -> Result {
        var builder = Builder()
        tokenize(html, builder: &builder)
        var media = builder.media
        var text = builder.result()
        text = convertMath(text)
        text = text.replacing(/\[sound:([^\]\n]+)\]/) { match in
            let name = decodeEntities(String(match.1))
            media.append(name)
            return "![[\(name)]]"
        }
        // 空的程式碼區塊（`<pre><br></pre>`）
        text = text.replacing(/(?m)^```\n(?:[ \t]*\n)*```(?:\n|$)/, with: "")
        text = collapseBlankLines(text)
        return Result(markdown: text, media: media)
    }

    /// 第一個欄位開頭的麵包屑「`X > Y > Z`」加換行：回傳各層與其餘的 HTML；沒有麵包屑時 `crumbs` 為空
    static func breadcrumb(_ html: String) -> (crumbs: [String], rest: String) {
        let text = html.replacingOccurrences(of: "&nbsp;", with: " ")
        guard let match = text.prefixMatch(of: /\s*((?:[^<\n]*?&gt;\s*)+[^<\n]*?)\s*(?:<br\s*\/?>\s*)+/.ignoresCase()) else {
            return ([], html)
        }
        let crumbs = match.1.components(separatedBy: "&gt;")
            .map { decodeEntities($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (crumbs, String(text[match.range.upperBound...]))
    }

    // MARK: 公式

    /// MathJax `\(…\)` → `$…$`、`\[…\]` → `$$…$$`；舊的 `[$]…[/$]`、`[$$]…[/$$]` 同樣轉換。不跨行
    static func convertMath(_ text: String) -> String {
        var s = text
        s = s.replacing(/\\\[(.+?)\\\]/) { "$$" + $0.1.trimmingCharacters(in: .whitespaces) + "$$" }
        s = s.replacing(/\\\((.+?)\\\)/) { "$" + $0.1.trimmingCharacters(in: .whitespaces) + "$" }
        // 文字中的 `$` 已經寫成 `\$`，所以這兩種寫法的 `$` 前面可能有反斜線
        s = s.replacing(/\[\\?\$\\?\$\](.+?)\[\/\\?\$\\?\$\]/) { "$$" + $0.1.trimmingCharacters(in: .whitespaces) + "$$" }
        s = s.replacing(/\[\\?\$\](.+?)\[\/\\?\$\]/) { "$" + $0.1.trimmingCharacters(in: .whitespaces) + "$" }
        return s
    }

    static func collapseBlankLines(_ text: String) -> String {
        var s = text.replacing(/\n{3,}/, with: "\n\n")
        // 清單項目之間的空行（Anki 常在 <ul> 之間多一個 <br>）
        s = s.replacing(/(?m)^([ \t]*(?:-|\d+\.) .*)\n\n(?=[ \t]*(?:-|\d+\.) )/) { "\($0.1)\n" }
        return s.trimmingCharacters(in: .newlines)
    }

    // MARK: Tokenizer

    private static func tokenize(_ html: String, builder: inout Builder) {
        var i = html.startIndex
        var text = ""
        func flush() {
            if !text.isEmpty { builder.text(decodeEntities(text)) }
            text = ""
        }
        while i < html.endIndex {
            let c = html[i]
            let next = html.index(after: i)
            guard c == "<", next < html.endIndex,
                  html[next].isLetter || html[next] == "/" || html[next] == "!" else {
                text.append(c)
                i = next
                continue
            }
            if html[i...].hasPrefix("<!--") {
                flush()
                i = html[i...].range(of: "-->")?.upperBound ?? html.endIndex
                continue
            }
            guard let close = html[next...].firstIndex(of: ">") else {
                text.append(c)
                i = next
                continue
            }
            flush()
            var inner = html[next..<close]
            let closing = inner.hasPrefix("/")
            if closing { inner = inner.dropFirst() }
            let name = inner.prefix { $0.isLetter || $0.isNumber }.lowercased()
            if closing {
                builder.end(name)
            } else {
                builder.start(name, attributes: attributes(inner.dropFirst(name.count)))
            }
            i = html.index(after: close)
        }
        flush()
    }

    private static func attributes(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: /([A-Za-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/) {
            let value = match.2 ?? match.3 ?? match.4 ?? ""
            result[match.1.lowercased()] = decodeEntities(String(value))
        }
        return result
    }

    // MARK: Entities

    private static let named: [String: String] = [
        "nbsp": " ", "lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'", "ndash": "–", "mdash": "—",
        "hellip": "…", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "middot": "·", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±", "copy": "©", "reg": "®",
        "trade": "™", "bull": "•", "rarr": "→", "larr": "←", "harr": "↔", "uarr": "↑", "darr": "↓",
    ] // l10n:fixed

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]{2,8});/) { match in
            let body = String(match.1)
            if body.hasPrefix("#") {
                let hex = body.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = body.dropFirst(hex ? 2 : 1)
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value), value != 0 {
                    return String(Character(scalar))
                }
                return String(match.0)
            }
            return named[body] ?? String(match.0)
        }
    }

    // MARK: Builder

    private struct Builder {
        private(set) var lines = [""]
        private(set) var media: [String] = []
        private var lists: [(ordered: Bool, count: Int)] = []
        /// 開啟中的行內樣式記號；換行時每行各自成對
        private var styles: [String] = []
        private var link: String?
        private var pre = false
        private var code = 0

        private static let inline = ["b": "**", "strong": "**", "i": "*", "em": "*", "s": "~~", "strike": "~~",
                                     "del": "~~"] // l10n:fixed

        private var current: String {
            get { lines[lines.count - 1] }
            set { lines[lines.count - 1] = newValue }
        }

        /// 清單符號之後還沒有文字（`- `、`1. `，可能帶著重新開啟的樣式記號）
        private var onlyMarker: Bool {
            current.wholeMatch(of: /[ \t]*(?:-|\d+\.) (?:\*\*|\*|~~)*[ \t]*/) != nil
        }

        /// 去掉樣式記號後沒有文字
        private var contentEmpty: Bool {
            current.replacing(/\*\*|\*|~~/, with: "").allSatisfy(\.isWhitespace)
        }

        private mutating func write(_ s: String) { current += s }

        private mutating func newline(force: Bool = false) {
            if onlyMarker { return }
            if !styles.isEmpty {
                if contentEmpty {
                    current = ""
                } else {
                    current = current.trimmingTrailingWhitespace + styles.reversed().joined()
                }
            }
            if force || !current.allSatisfy(\.isWhitespace) { lines.append("") }
            current += styles.joined()
        }

        mutating func start(_ tag: String, attributes: [String: String]) {
            if pre {
                if tag == "br" { lines.append("") }
                return
            }
            switch tag {
            case "br":
                newline(force: true)
            case "div", "p":
                newline()
            case "ul", "ol":
                newline()
                lists.append((tag == "ol", 0))
            case "li":
                newline()
                if lists.isEmpty { lists.append((false, 0)) }
                lists[lists.count - 1].count += 1
                let item = lists[lists.count - 1]
                write(String(repeating: "  ", count: lists.count - 1) + (item.ordered ? "\(item.count). " : "- "))
            case "code":
                write("`")
                code += 1
            case "a":
                link = attributes["href"]
                write("[")
            case "img":
                guard let src = attributes["src"], let name = AnkiPackage.safeMediaName(src) else { return }
                media.append(name)
                newline()
                write("![[\(name)]]")
                newline(force: true)
            case "pre":
                newline()
                write("```")
                lines.append("")
                pre = true
            default:
                if let mark = Self.inline[tag] {
                    styles.append(mark)
                    write(mark)
                }
            }
        }

        mutating func end(_ tag: String) {
            if tag == "pre" {
                pre = false
                if !current.isEmpty { lines.append("") }
                write("```")
                lines.append("")
                return
            }
            if pre { return }
            switch tag {
            case "div", "p", "li":
                newline()
            case "ul", "ol":
                if !lists.isEmpty { lists.removeLast() }
                newline()
            case "code":
                write("`")
                code = max(0, code - 1)
            case "a":
                write(link.map { "](\($0))" } ?? "]")
                link = nil
            default:
                guard let mark = Self.inline[tag], let index = styles.lastIndex(of: mark) else { return }
                if current.hasSuffix(mark) {
                    // 空的樣式
                    current.removeLast(mark.count)
                } else {
                    // 結尾的空白移到樣式外（`**a **` 不是粗體）
                    let body = current.trimmingTrailingWhitespace
                    current = body + mark + current.dropFirst(body.count)
                }
                styles.remove(at: index)
            }
        }

        mutating func text(_ raw: String) {
            if pre {
                let parts = raw.components(separatedBy: "\n")
                write(parts[0])
                for part in parts.dropFirst() { lines.append(part) }
                return
            }
            var s = raw.replacingOccurrences(of: "\u{00A0}", with: " ").replacing(/\s*\n\s*/, with: " ")
            if contentEmpty || onlyMarker {
                s = String(s.drop { $0 == " " || $0 == "\t" })
                if s.isEmpty { return }
            }
            // Anki 的公式是 `\(…\)`，文字中的 `$` 一定不是公式；程式碼內原樣保留
            if code == 0 { s = s.replacingOccurrences(of: "$", with: "\\$") }
            write(s)
        }

        func result() -> String {
            lines.map { line in
                line.trimmingTrailingWhitespace.replacing(/\*\*[ \t]*\*\*|~~[ \t]*~~/, with: "")
            }.joined(separator: "\n")
        }
    }
}
