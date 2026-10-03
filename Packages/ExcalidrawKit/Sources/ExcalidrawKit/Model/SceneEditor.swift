import CoreGraphics
import Foundation

/// 場景編輯的工作區：把元素陣列載入、修改、寫回。所有會牽動其他元素的操作
/// （刪除、移動、綁定、文字排版）都在這裡，`ExcalidrawScene` 的公開方法只是薄薄一層。
struct SceneEditor {
    var elements: [Element]
    private(set) var position: [String: Int]

    init(_ elements: [Element]) {
        self.elements = elements
        position = Dictionary(elements.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    subscript(id: String) -> Element? {
        position[id].map { elements[$0] }
    }

    /// 修改元素的共用路徑：內容有變才遞增 `version`、重抽 `versionNonce`、更新 `updated`
    @discardableResult
    mutating func update(_ id: String, _ body: (inout Element) -> Void) -> Bool {
        guard let i = position[id] else { return false }
        var el = elements[i]
        body(&el)
        guard !el.isEqual(to: elements[i]) else { return false }
        el.touch()
        elements[i] = el
        return true
    }

    func children(ofFrame id: String) -> [Element] {
        elements.filter { $0.frameId == id && !$0.isDeleted }
    }

    func boundTexts(of containerID: String) -> [Element] {
        elements.filter { $0.containerId == containerID && !$0.isDeleted }
    }

    // MARK: 順序與插入

    /// 所有元素都有合法的 `index`（空場景也算）：依它排序、新元素產生 index。
    /// 沒有 `index` 的舊檔案沿用陣列順序，不替既有元素補 index（補了要遞增每個元素的 version）。
    var isIndexed: Bool {
        elements.allSatisfy { $0.index.map(FractionalIndex.isValid) ?? false }
    }

    /// 依 index 排序（index 相同時依 id，所以兩台裝置的結果一致）；舊檔案維持陣列順序
    static func sorted(_ elements: [Element]) -> [Element] {
        guard !elements.isEmpty, SceneEditor(elements).isIndexed else { return elements }
        return elements.sorted { a, b in
            if a.index != b.index { return FractionalIndex.less(a.index!, b.index!) }
            return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
        }
    }

    /// 插入到 `at`（在完整順序中的位置，含已刪除的元素；nil = 最上層）
    mutating func insert(_ element: Element, at requested: Int? = nil) {
        var el = element
        var pos = min(max(requested ?? elements.count, 0), elements.count)
        if isIndexed {
            elements = Self.sorted(elements)
            pos = min(max(requested ?? elements.count, 0), elements.count)
            let lower = pos > 0 ? elements[pos - 1].index : nil
            // 兩台裝置在同一處插入、合併後會有相同的 index：越過這一串，從下一個較大的 index 之前插入
            if let lower { while pos < elements.count, elements[pos].index == lower { pos += 1 } }
            let upper = pos < elements.count ? elements[pos].index : nil
            el.index = try? FractionalIndex.between(lower, upper)
        }
        elements.insert(el, at: pos)
        rebuildPosition()
    }

    /// 元素在完整順序中的位置
    func orderIndex(of id: String) -> Int? {
        Self.sorted(elements).firstIndex { $0.id == id }
    }

    mutating func rebuildPosition() {
        position = Dictionary(elements.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: 刪除

    /// 刪除是墓碑（`isDeleted`），合併依賴它。連帶處理：frame 的子元素、形狀內的文字一併刪除；
    /// 被刪形狀上的箭頭綁定清除；被刪箭頭從形狀的 `boundElements` 移除。
    mutating func delete(_ ids: Set<String>) {
        var doomed = Set(ids.filter { self[$0] != nil && self[$0]?.isDeleted == false })
        for id in doomed {
            guard let el = self[id] else { continue }
            if el.type == .frame { children(ofFrame: id).forEach { doomed.insert($0.id) } }
            boundTexts(of: id).forEach { doomed.insert($0.id) }
        }
        for id in doomed { update(id) { $0.isDeleted = true } }

        for id in doomed {
            guard let el = self[id] else { continue }
            if el.type == .arrow {
                for end in [ArrowEnd.start, .end] {
                    if let target = el.binding(end)?.elementId, !doomed.contains(target) { removeBound(id, from: target) }
                }
            }
            if let container = el.containerId, !doomed.contains(container) { removeBound(id, from: container) }
        }
        // 綁在被刪形狀上的箭頭（箭頭本身沒被刪）：清除綁定
        for arrow in elements where arrow.type == .arrow && !arrow.isDeleted {
            for end in [ArrowEnd.start, .end] {
                if let b = arrow.binding(end), doomed.contains(b.elementId) {
                    update(arrow.id) { $0.setBinding(end, nil) }
                }
            }
        }
    }

    // MARK: boundElements

    mutating func addBound(_ id: String, type: String, to containerID: String) {
        update(containerID) { c in
            var bound = c.boundElements
            if !bound.contains(where: { $0.id == id }) { bound.append((id, type)) }
            c.boundElements = bound
        }
    }

    mutating func removeBound(_ id: String, from containerID: String) {
        update(containerID) { c in c.boundElements = c.boundElements.filter { $0.id != id } }
    }

    // MARK: 移動

    /// 移動元素。frame 帶動子元素，形狀帶動內部文字；箭頭綁定的形狀沒一起移動時解除該端綁定；
    /// 其餘綁在移動形狀上的箭頭重算端點。
    mutating func move(_ ids: Set<String>, dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        var moving = Set(ids.filter { self[$0]?.isDeleted == false })
        for id in moving {
            if self[id]?.type == .frame { children(ofFrame: id).forEach { moving.insert($0.id) } }
        }
        for id in moving { boundTexts(of: id).forEach { moving.insert($0.id) } }

        for id in moving {
            update(id) { $0.x += dx; $0.y += dy }
            guard let el = self[id], el.type == .arrow else { continue }
            for end in [ArrowEnd.start, .end] {
                if let target = el.binding(end)?.elementId, !moving.contains(target) { unbind(id, end) }
            }
        }
        rebindArrows(movedIDs: moving)
    }

    // MARK: 縮放

    /// 把元素縮放到 `rect`（未旋轉的外框，見 `ElementGeometry.box`）。線與箭頭的點依外框等比例換算；
    /// 獨立文字依高度縮放字級；形狀內的文字重新排版（容器高度不夠會長高）；綁定的箭頭重算端點。
    /// `original` = 開始縮放時的元素：拖曳中每一幀都從它計算，不累積誤差（省略時用目前的元素）。
    mutating func resize(_ id: String, to rect: CGRect, from original: Element? = nil) {
        guard let current = self[id], !current.isDeleted else { return }
        let old = original ?? current
        var touched: Set<String> = [id]
        switch old.type {
        case .line, .arrow, .freedraw:
            let box = ElementGeometry.box(old)
            let sx = box.width > 0 ? rect.width / box.width : 1
            let sy = box.height > 0 ? rect.height / box.height : 1
            let pts = old.absolutePoints.map {
                CGPoint(x: rect.minX + ($0.x - box.minX) * sx, y: rect.minY + ($0.y - box.minY) * sy)
            }
            update(id) { $0.setAbsolutePoints(pts) }
        case .text where old.containerId == nil:
            let scale = old.height > 0 ? rect.height / old.height : 1
            update(id) { el in
                el.raw["fontSize"] = (old.fontSize * scale * 10).rounded() / 10
                el.x = rect.minX; el.y = rect.minY
                TextLayout.fit(&el, maxWidth: el.raw["autoResize"] as? Bool == false ? rect.width : nil)
            }
        default:
            update(id) { el in
                el.x = rect.minX; el.y = rect.minY; el.width = rect.width; el.height = rect.height
            }
            if layoutBoundText(in: id) { touched.insert(id) }
        }
        rebindArrows(movedIDs: touched)
    }

    // MARK: frame

    /// 指定（或清除）元素所屬的 frame
    mutating func setFrame(_ ids: Set<String>, to frameID: String?) {
        for id in ids where self[id]?.type != .frame { update(id) { $0.frameId = frameID } }
    }

    // MARK: 文字

    /// 設定文字內容。形狀內的文字依容器排版，獨立文字依 `autoResize` 決定是否換行。
    mutating func setText(_ id: String, to text: String) {
        guard let el = self[id], el.type == .text else { return }
        if let container = el.containerId, self[container] != nil {
            update(id) { $0.raw["originalText"] = text }
            if layoutBoundText(in: container) { rebindArrows(movedIDs: [container]) }
        } else {
            update(id) { el in
                el.raw["originalText"] = text
                TextLayout.fit(&el, maxWidth: el.raw["autoResize"] as? Bool == false ? el.width : nil)
            }
        }
    }

    /// 在形狀內加文字（`containerId` 綁定，置中換行）；形狀已有文字就改寫它。回傳文字元素 id。
    @discardableResult
    mutating func addBoundText(_ text: String, to containerID: String) -> String? {
        guard let container = self[containerID], !container.isDeleted else { return nil }
        switch container.type {
        case .rectangle, .ellipse, .diamond: break
        default: return nil
        }
        if let existing = boundTexts(of: containerID).first {
            setText(existing.id, to: text)
            return existing.id
        }
        var el = Element.text(text, x: container.x, y: container.y)
        el.containerId = containerID
        el.raw["textAlign"] = "center"
        el.raw["verticalAlign"] = "middle"
        el.angle = container.angle
        el.frameId = container.frameId
        insert(el, at: (orderIndex(of: containerID) ?? elements.count - 1) + 1)
        addBound(el.id, type: "text", to: containerID)
        if layoutBoundText(in: containerID) { rebindArrows(movedIDs: [containerID]) }
        return el.id
    }

    /// 重新排版容器內的文字：換行、置中；文字比容器高就讓容器長高。回傳容器尺寸是否改變。
    @discardableResult
    mutating func layoutBoundText(in containerID: String) -> Bool {
        guard let container = self[containerID], let textEl = boundTexts(of: containerID).first else { return false }
        let maxWidth = TextLayout.maxWidth(in: container)
        let source = textEl.originalText
        let result = TextLayout.layout(source, fontSize: textEl.fontSize, lineHeight: textEl.lineHeight, maxWidth: maxWidth)

        var grew = false
        let needed = TextLayout.containerHeight(fitting: result.size.height, in: container)
        if needed > container.height {
            grew = update(containerID) { $0.height = needed }
        }
        let c = self[containerID]!
        update(textEl.id) { t in
            t.raw["text"] = result.lines.joined(separator: "\n")
            t.raw["originalText"] = source
            t.width = result.size.width
            t.height = result.size.height
            t.x = c.center.x - t.width / 2
            t.y = c.center.y - t.height / 2
            t.angle = c.angle
        }
        return grew
    }
}
