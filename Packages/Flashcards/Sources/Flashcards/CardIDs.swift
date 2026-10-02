import CryptoKit
import Foundation

/// 替卡片補上或修正 `^id`。
///
/// id 由「檔案路徑 + 該行內容」的 hash 決定：兩台裝置替同一行補 id 會得到相同結果，
/// diff3 視為相同的修改，不會產生衝突。
public enum CardIDs {
    /// 回傳補好 id 的內容；不需要修改時回傳 nil。
    /// - 缺少 id 的卡片補上 id
    /// - 同一檔案內重複的 id：保留第一個，後出現的改掉
    /// - `takenElsewhere`：已被其他檔案使用的 id（複製貼上的新位置），這個檔案中的改掉
    public static func fill(_ text: String, path: String, takenElsewhere: (String) -> Bool = { _ in false }) -> String? {
        let parsed = CardSyntax.parseLines(text)
        let inFile = Set(parsed.compactMap(\.note.id))
        var kept = Set<String>()
        var replacements: [Int: String] = [:]
        var lines = CardSyntax.lines(text)

        for item in parsed {
            if let id = item.note.id, !kept.contains(id), !takenElsewhere(id) {
                kept.insert(id)
                continue
            }
            var attempt = 0
            var id = make(path: path, content: item.content, attempt: attempt)
            // 不能撞到這個檔案稍後才出現的 id，否則那一行會變成重複
            while kept.contains(id) || inFile.contains(id) || takenElsewhere(id) {
                attempt += 1
                id = make(path: path, content: item.content, attempt: attempt)
            }
            kept.insert(id)
            replacements[item.note.line] = id

            let raw = lines[item.note.line]
            let cr = raw.hasSuffix("\r") ? "\r" : ""
            var line = cr.isEmpty ? raw : String(raw.dropLast())
            if let range = item.idRange {
                let from = line.index(line.startIndex, offsetBy: range.lowerBound)
                let to = line.index(line.startIndex, offsetBy: range.upperBound)
                // 範圍包含行尾空白，一併保留
                let trailing = line[from..<to].drop { !$0.isWhitespace }
                line.replaceSubrange(from..<to, with: "^" + id + trailing)
            } else {
                // 插在行尾空白之前（保留 Markdown 的兩個空白換行）
                let end = line.index(line.startIndex, offsetBy: line.trimmingTrailingWhitespace.count)
                line.insert(contentsOf: " ^" + id, at: end)
            }
            lines[item.note.line] = line + cr
        }
        return replacements.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// `c-` + 6 碼小寫英數
    static func make(path: String, content: String, attempt: Int) -> String {
        let digest = SHA256.hash(data: Data("\(path)\n\(content)\n\(attempt)".utf8))
        var value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var chars: [Character] = []
        for _ in 0..<6 {
            chars.append(alphabet[Int(value % 36)])
            value /= 36
        }
        return "c-" + String(chars)
    }
}
