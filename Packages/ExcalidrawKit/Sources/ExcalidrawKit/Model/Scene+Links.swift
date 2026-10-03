import Foundation

extension ExcalidrawScene {
    /// 元素 `link` 中的 `[[筆記]]`（不含別名），已刪除的元素不算
    public var noteLinks: [String] {
        var seen = Set<String>(), result: [String] = []
        for el in liveElements {
            guard let link = el.link, let name = Self.wikiTarget(link), seen.insert(name).inserted else { continue }
            result.append(name)
        }
        return result
    }

    /// 筆記改名：更新 `link` 的 `[[舊名]]`（保留別名、不分大小寫）與 `customData.easynotes.file`
    /// （筆記卡片記錄的路徑，只換檔名、保留資料夾與副檔名）。沒有要改的回傳 false。
    @discardableResult
    public mutating func renameLinks(from oldName: String, to newName: String) -> Bool {
        var changed = false
        for el in orderedElements where !el.isDeleted {
            let link = el.link.flatMap { Self.renamed(link: $0, from: oldName, to: newName) }
            let file = Self.renamedFile(in: el.customData, from: oldName, to: newName)
            guard link != nil || file != nil else { continue }
            mutate(el.id) { e in
                if let link { e.link = link }
                if let file {
                    var custom = e.customData ?? [:]
                    var mine = custom[Self.customKey] as? [String: Any] ?? [:]
                    mine["file"] = file
                    custom[Self.customKey] = mine
                    e.raw["customData"] = custom
                }
            }
            changed = true
        }
        return changed
    }

    static func wikiTarget(_ link: String) -> String? {
        guard let m = linkRegex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
              let r = Range(m.range(at: 1), in: link)
        else { return nil }
        let name = link[r].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static let linkRegex = try! NSRegularExpression(pattern: #"^\s*!?\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]\s*$"#)

    private static func renamed(link: String, from oldName: String, to newName: String) -> String? {
        let pattern = #"^(\s*!?\[\[)"# + NSRegularExpression.escapedPattern(for: oldName) + #"((?:\|[^\]\n]*)?\]\]\s*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)) != nil
        else { return nil }
        return regex.stringByReplacingMatches(in: link, range: NSRange(link.startIndex..., in: link),
                                              withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: newName) + "$2")
    }

    private static func renamedFile(in customData: [String: Any]?, from oldName: String, to newName: String) -> String? {
        guard let path = (customData?[customKey] as? [String: Any])?["file"] as? String else { return nil }
        let ns = path as NSString
        guard (ns.lastPathComponent as NSString).deletingPathExtension.caseInsensitiveCompare(oldName) == .orderedSame
        else { return nil }
        let ext = ns.pathExtension
        let name = ext.isEmpty ? newName : newName + "." + ext
        return (ns.deletingLastPathComponent as NSString).appendingPathComponent(name)
    }
}
