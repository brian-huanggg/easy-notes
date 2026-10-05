import Foundation

extension ExcalidrawScene {
    /// The `[[note]]` in an element's `link` (without alias); deleted elements do not count
    public var noteLinks: [String] {
        var seen = Set<String>(), result: [String] = []
        for el in liveElements {
            guard let link = el.link, let name = Self.wikiTarget(link), seen.insert(name).inserted else { continue }
            result.append(name)
        }
        return result
    }

    /// Note rename: updates `[[old name]]` in `link` (keeping alias, case-insensitive) and `customData.easynotes.file`
    /// (the path a note card records; only the file name is replaced, keeping folder and extension). Returns false when there is nothing to change.
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
            // A card's title text follows the rename (left alone if the user changed the title)
            if link != nil, let title = liveElements.first(where: { $0.containerId == el.id && $0.type == .text }),
               title.text.caseInsensitiveCompare(oldName) == .orderedSame {
                setText(title.id, to: newName)
            }
        }
        return changed
    }

    /// A note card: the vault path recorded in `customData.easynotes.file`; nil if not a card
    public func noteCardPath(_ id: String) -> String? {
        guard let el = element(id), !el.isDeleted else { return nil }
        return Self.cardFile(in: el.customData)
    }

    /// Inserts a note card in `box` (rectangle + `link: [[note name]]` + `customData.easynotes.file`),
    /// with the title as text bound inside the rectangle, shown as a box with a link on excalidraw.com. Returns the card id
    @discardableResult
    public mutating func insertNoteCard(path: String, in box: CGRect) -> String {
        let name = (((path as NSString).lastPathComponent) as NSString).deletingPathExtension
        var card = Element.rectangle(x: box.minX, y: box.minY, width: box.width, height: box.height)
        card.raw["backgroundColor"] = "#ffffff"
        card.link = "[[\(name)]]"
        // fit: the height after the card auto-fit to its content; once the user changes the height by hand (≠ fit) it is never auto-adjusted again
        card.raw["customData"] = [Self.customKey: ["file": path, "fit": box.height]]
        insert(card)
        addBoundText(name, to: card.id)
        return card.id
    }

    /// The card height follows content: adjusts only while the height still equals the last auto-fit result (`fit`; no record counts as auto),
    /// and leaves it alone once the user has changed the height by hand. Title text is re-centered and bound arrows recomputed. Returns true when changed
    @discardableResult
    public mutating func fitNoteCard(_ id: String, toHeight height: Double) -> Bool {
        guard let el = element(id), !el.isDeleted, noteCardPath(id) != nil else { return false }
        let mine = el.customData?[Self.customKey] as? [String: Any]
        let fit = (mine?["fit"] as? NSNumber)?.doubleValue ?? el.height
        guard abs(el.height - fit) < 1, abs(height - el.height) >= 1 else { return false }
        edit { editor in
            _ = editor.update(id) { e in
                e.height = height
                var custom = e.customData ?? [:]
                var inner = custom[Self.customKey] as? [String: Any] ?? [:]
                inner["fit"] = height
                custom[Self.customKey] = inner
                e.raw["customData"] = custom
            }
            editor.layoutBoundText(in: id)
            editor.rebindArrows(movedIDs: [id])
        }
        return true
    }

    static func cardFile(in customData: [String: Any]?) -> String? {
        (customData?[customKey] as? [String: Any])?["file"] as? String
    }

    static func wikiTarget(_ link: String) -> String? {
        guard let m = linkRegex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
              let r = Range(m.range(at: 1), in: link)
        else { return nil }
        let name = link[r].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static let linkRegex = try! NSRegularExpression(pattern: #"^\s*!?\[\[([^\[\]\n|]+)(?:\|[^\[\]\n]*)?\]\]\s*$"#)

    private static func renamed(link: String, from oldName: String, to newName: String) -> String? {
        let pattern = #"^(\s*!?\[\[)"# + NSRegularExpression.escapedPattern(for: oldName) + #"((?:\|[^\[\]\n]*)?\]\]\s*)$"#
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
