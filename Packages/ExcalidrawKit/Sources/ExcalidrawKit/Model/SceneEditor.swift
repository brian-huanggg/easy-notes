import CoreGraphics
import Foundation

/// The workspace of scene editing: loads the element array, modifies, writes back. All operations that affect other elements
/// (delete, move, bind, text layout) live here, and `ExcalidrawScene`'s public methods are just a thin layer.
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

    /// The shared path for modifying elements: increments `version`, redraws `versionNonce` and updates `updated` only when content changed
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

    // MARK: Order and insertion

    /// Every element has a valid `index` (an empty scene counts too): sort by it and generate indexes for new elements.
    /// Older files without `index` keep array order and existing elements are not backfilled (backfilling would increment every element's version).
    var isIndexed: Bool {
        elements.allSatisfy { $0.index.map(FractionalIndex.isValid) ?? false }
    }

    /// Sort by index (ties by id, so two devices get the same result); older files keep array order
    static func sorted(_ elements: [Element]) -> [Element] {
        guard !elements.isEmpty, SceneEditor(elements).isIndexed else { return elements }
        return elements.sorted { a, b in
            if a.index != b.index { return FractionalIndex.less(a.index!, b.index!) }
            return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
        }
    }

    /// Inserts at `at` (a position in the full order, including deleted elements; nil = top)
    mutating func insert(_ element: Element, at requested: Int? = nil) {
        var el = element
        var pos = min(max(requested ?? elements.count, 0), elements.count)
        if isIndexed {
            elements = Self.sorted(elements)
            pos = min(max(requested ?? elements.count, 0), elements.count)
            let lower = pos > 0 ? elements[pos - 1].index : nil
            // Two devices inserting at the same spot get the same index after merging: skip past this run and insert before the next larger index
            if let lower { while pos < elements.count, elements[pos].index == lower { pos += 1 } }
            let upper = pos < elements.count ? elements[pos].index : nil
            el.index = try? FractionalIndex.between(lower, upper)
        }
        elements.insert(el, at: pos)
        rebuildPosition()
    }

    /// The element's position in the full order
    func orderIndex(of id: String) -> Int? {
        Self.sorted(elements).firstIndex { $0.id == id }
    }

    mutating func rebuildPosition() {
        position = Dictionary(elements.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Delete

    /// Deletion is a tombstone (`isDeleted`), which merging relies on. Side effects: a frame's children and text inside shapes are deleted too;
    /// arrow bindings on the deleted shape are cleared; a deleted arrow is removed from the shapes' `boundElements`.
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
        // Arrows bound to the deleted shape (the arrow itself not deleted): clear the binding
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

    // MARK: Move

    /// Moves elements. A frame carries its children and a shape carries the text inside; when the shape an arrow is bound to did not move along, that end's binding is released;
    /// other arrows bound to the moved shape recompute their endpoints.
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

    // MARK: Resize

    /// Scales an element to `rect` (the unrotated bounding box, see `ElementGeometry.box`). Points of lines and arrows are converted proportionally to the box;
    /// standalone text scales the font size by height; text inside a shape is re-laid out (the container grows if too short); bound arrows recompute endpoints.
    /// `original` = the element when scaling began: every frame during the drag is computed from it so errors do not accumulate (the current element is used if omitted).
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

    /// Assigns (or clears) the frame an element belongs to
    mutating func setFrame(_ ids: Set<String>, to frameID: String?) {
        for id in ids where self[id]?.type != .frame { update(id) { $0.frameId = frameID } }
    }

    // MARK: Text

    /// Sets text content. Text inside a shape is laid out by its container; standalone text decides wrapping by `autoResize`.
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

    /// Adds text inside a shape (bound with `containerId`, centered and wrapped); if the shape already has text it is rewritten. Returns the text element's id.
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

    /// Re-lays out text inside a container: wrap, center; if the text is taller than the container the container grows. Returns whether the container size changed.
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
