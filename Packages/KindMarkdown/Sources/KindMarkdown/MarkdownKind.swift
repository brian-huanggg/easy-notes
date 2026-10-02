import EasyNotesCore
import Foundation

public enum MarkdownKind: DocumentKind {
    public static let id = "markdown"
    public static let fileExtensions = ["md", "markdown"]

    public static func template(title: String) -> Data {
        Data("# \(title)\n\n".utf8)
    }

    public static func index(_ data: Data, fileName: String) -> IndexEntry {
        let text = String(decoding: data, as: UTF8.self)
        let frontmatter = Frontmatter(text)
        let body = String(Frontmatter.body(of: text))

        let heading = body.split(separator: "\n", omittingEmptySubsequences: true)
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        let fallback = (fileName as NSString).deletingPathExtension

        return IndexEntry(
            title: heading ?? fallback,
            plainText: body,
            links: matches(of: #"\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]"#, in: body),
            tags: unique(frontmatter.list("tags") + matches(of: #"(?<![\p{L}\p{N}_#&/])#([\p{L}\p{N}_/-]+)"#, in: body)),
            icon: frontmatter.scalar("icon"),
            pinned: frontmatter.bool("pinned"),
            summary: L("\(wordCount(body).formatted(.number)) 字")
        )
    }

    /// diff3 以行為單位合併；沒有共同基準（兩台裝置各自新建同名檔）時只接受完全相同的內容
    public static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        guard let base else { return local == remote ? local : nil }
        return Diff3.merge(base: base, local: local, remote: remote)
    }

    public static func renameLinks(in data: Data, from oldName: String, to newName: String) -> Data? {
        let text = String(decoding: data, as: UTF8.self)
        let updated = renameLinks(in: text, from: oldName, to: newName)
        return updated == text ? nil : Data(updated.utf8)
    }

    /// 筆記改名時更新 `[[舊名]]` / `[[舊名|別名]]` / `![[舊名]]`，保留別名，不分大小寫
    public static func renameLinks(in text: String, from oldName: String, to newName: String) -> String {
        let pattern = #"(!?\[\[)"# + NSRegularExpression.escapedPattern(for: oldName) + #"((?:\|[^\]\n]*)?\]\])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let template = "$1" + NSRegularExpression.escapedTemplate(for: newName) + "$2"
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// 釘選寫在 frontmatter 的 `pinned: true`；取消時移除該行（frontmatter 變空就整個移除）
    public static func setPinned(_ pinned: Bool, in data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self)
        return Data(Frontmatter(text).setting("pinned", to: pinned ? "true" : nil, in: text).utf8)
    }

    /// 字數：中日韓文字每字算一個，其他語言以連續的字母數字為一個詞
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let value = ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return seen.insert(value).inserted ? value : nil
        }
    }
}
