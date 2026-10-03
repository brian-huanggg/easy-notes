import CoreGraphics
import Foundation

/// Undo 的寫回、再製、複製與貼上
extension ExcalidrawScene {
    /// 元素 id → 原始字典（nil = 當時不存在）。Undo 記下操作前後各一份
    public typealias Snapshot = [String: [String: Any]?]

    /// 寫回 `snapshot` 的內容，但 `version` 一律繼續遞增（不回到舊版號），其他裝置合併時才不會丟掉復原。
    /// nil = 當時不存在的元素（例如新建的）→ 標記刪除。
    public mutating func restore(_ snapshot: Snapshot) {
        edit { $0.restore(snapshot) }
    }

    /// 再製：複製到最上層並位移；形狀內的文字、frame 的子元素一起複製，彼此的綁定改指向複本。回傳新元素的 id
    @discardableResult
    public mutating func duplicate(_ ids: Set<String>, offset: CGPoint) -> [String] {
        let copies = Self.copies(of: closure(of: ids), offset: offset)
        for el in copies { insert(el) }
        return copies.map(\.id)
    }

    // MARK: 剪貼簿（與 Excalidraw 相同的 `excalidraw/clipboard` JSON）

    public static let clipboardType = "excalidraw/clipboard"

    /// 複製選取的元素（含形狀內的文字、frame 的子元素與用到的圖片）
    public func clipboardData(_ ids: Set<String>) -> Data? {
        let elements = closure(of: ids)
        guard !elements.isEmpty else { return nil }
        let allFiles = raw["files"] as? [String: Any] ?? [:]
        let files = allFiles.filter { key, _ in elements.contains { $0.fileId == key } }
        return try? JSONSerialization.data(withJSONObject: [
            "type": Self.clipboardType, "elements": elements.map(\.raw), "files": files,
        ], options: [.sortedKeys])
    }

    /// 貼上剪貼簿的元素，整體中心放在 `center`。不是 Excalidraw 剪貼簿回傳 nil
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

    // MARK: 內部

    /// 選取的元素加上跟著它們的元素（形狀內的文字、frame 的子元素），依渲染順序
    private func closure(of ids: Set<String>) -> [Element] {
        let live = liveElements
        var included = ids
        for el in live where ids.contains(el.id) && el.type == .frame {
            live.filter { $0.frameId == el.id }.forEach { included.insert($0.id) }
        }
        for el in live where el.containerId.map(included.contains) == true { included.insert(el.id) }
        return live.filter { included.contains($0.id) }
    }

    /// 新 id、新版號、位移；群組、容器、frame、箭頭綁定只在複本之間保留，指向外部的清除
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
                // 之後被外部整個移除（不是墓碑）：放回去
                el.touch()
                elements.append(el)
                appended = true
            }
        }
        if appended { rebuildPosition() }
    }
}
