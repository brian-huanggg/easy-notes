import CoreGraphics
import Foundation

/// Undo write-back, duplicate, copy and paste
extension ExcalidrawScene {
    /// Element id → raw dictionary (nil = did not exist then). Undo records one copy before and one after the operation
    public typealias Snapshot = [String: [String: Any]?]

    /// Writes back the content of `snapshot` but `version` always keeps increasing (never returning to the old number), so other devices do not drop the undo when merging.
    /// nil = an element that did not exist then (for example newly created) → marked deleted.
    public mutating func restore(_ snapshot: Snapshot) {
        edit { $0.restore(snapshot) }
    }

    /// Duplicate: copies to the top and offsets; text inside shapes and a frame's children are copied along, with their mutual bindings pointing at the copies. Returns the new elements' ids
    @discardableResult
    public mutating func duplicate(_ ids: Set<String>, offset: CGPoint) -> [String] {
        let copies = Self.copies(of: closure(of: ids), offset: offset)
        for el in copies { insert(el) }
        return copies.map(\.id)
    }

    // MARK: Clipboard (the same `excalidraw/clipboard` JSON as Excalidraw)

    public static let clipboardType = "excalidraw/clipboard"

    /// Copies the selected elements (including text inside shapes, a frame's children and the images used)
    public func clipboardData(_ ids: Set<String>) -> Data? {
        let elements = closure(of: ids)
        guard !elements.isEmpty else { return nil }
        let allFiles = raw["files"] as? [String: Any] ?? [:]
        let files = allFiles.filter { key, _ in elements.contains { $0.fileId == key } }
        return try? JSONSerialization.data(withJSONObject: [
            "type": Self.clipboardType, "elements": elements.map(\.raw), "files": files,
        ], options: [.sortedKeys])
    }

    /// Pastes clipboard elements with their overall center at `center`. Returns nil if it is not an Excalidraw clipboard
    public mutating func paste(_ data: Data, center: CGPoint) -> [String]? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["type"] as? String == Self.clipboardType,
              let raws = dict["elements"] as? [[String: Any]]
        else { return nil }
        let elements = raws.map(Element.init(raw:)).filter { !$0.isDeleted }
        guard let bounds = ElementGeometry.bounds(of: elements) else { return [] }
        if let files = dict["files"] as? [String: Any], !files.isEmpty {
            raw["files"] = (raw["files"] as? [String: Any] ?? [:]).merging(files) { mine, _ in mine }
        }
        let copies = Self.copies(of: elements, offset: CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY))
        for el in copies { insert(el) }
        return copies.map(\.id)
    }

    // MARK: Internal

    /// The selected elements plus the elements that follow them (text inside shapes, a frame's children), in render order
    private func closure(of ids: Set<String>) -> [Element] {
        let live = liveElements
        var included = ids
        for el in live where ids.contains(el.id) && el.type == .frame {
            live.filter { $0.frameId == el.id }.forEach { included.insert($0.id) }
        }
        for el in live where el.containerId.map(included.contains) == true { included.insert(el.id) }
        return live.filter { included.contains($0.id) }
    }

    /// New ids, new versions, offset; groups, containers, frames and arrow bindings are kept only among the copies, and references to outside are cleared
    private static func copies(of elements: [Element], offset: CGPoint) -> [Element] {
        var ids: [String: String] = [:]
        for el in elements { ids[el.id] = randomID() }
        var groups: [String: String] = [:]
        let now = Int(Date().timeIntervalSince1970 * 1000)

        return elements.map { source in
            var el = source
            el.raw["id"] = ids[source.id]
            el.x += offset.x
            el.y += offset.y
            el.raw["version"] = 1
            el.raw["versionNonce"] = Int.random(in: 1...Int(Int32.max))
            el.raw["seed"] = Int.random(in: 1...Int(Int32.max))
            el.raw["updated"] = now
            el.raw["index"] = NSNull()
            el.groupIds = source.groupIds.map { g in
                if let new = groups[g] { return new }
                let new = randomID()
                groups[g] = new
                return new
            }
            el.containerId = source.containerId.flatMap { ids[$0] }
            el.frameId = source.frameId.map { ids[$0] ?? $0 }
            el.boundElements = source.boundElements.compactMap { b in ids[b.id].map { ($0, b.type) } }
            for end in [ArrowEnd.start, .end] {
                guard var b = source.binding(end) else { continue }
                if let target = ids[b.elementId] { b.elementId = target; el.setBinding(end, b) } else { el.setBinding(end, nil) }
            }
            return el
        }
    }
}

extension SceneEditor {
    mutating func restore(_ snapshot: ExcalidrawScene.Snapshot) {
        var appended = false
        for (id, saved) in snapshot {
            guard let saved else {
                update(id) { $0.isDeleted = true }
                continue
            }
            var el = Element(raw: saved)
            if let i = position[id] {
                el.raw["version"] = max(elements[i].version, el.version)
                el.touch()
                elements[i] = el
            } else {
                // Later removed entirely from outside (not a tombstone): put it back
                el.touch()
                elements.append(el)
                appended = true
            }
        }
        if appended { rebuildPosition() }
    }
}
