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
        let body = stripFrontmatter(text)

        let heading = body.split(separator: "\n", omittingEmptySubsequences: true)
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        let fallback = (fileName as NSString).deletingPathExtension

        return IndexEntry(
            title: heading ?? fallback,
            plainText: body,
            links: matches(of: #"\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]"#, in: body),
            tags: matches(of: #"(?<![\p{L}\p{N}_#&/])#([\p{L}\p{N}_/-]+)"#, in: body)
        )
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

    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...])
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
