import CoreGraphics
import Foundation

/// The scene's typed editing API. The underlying value is still raw JSON dictionaries; every operation that modifies elements goes through
/// `SceneEditor.update`, so there is only one path that increments `version` / `versionNonce` / `updated`.
extension ExcalidrawScene {
    /// All elements including deleted (tombstone) ones, in render order (by `index` if present, otherwise array order)
    public var orderedElements: [Element] {
        SceneEditor.sorted(elements.map(Element.init(raw:)))
    }

    public var liveElements: [Element] {
        orderedElements.filter { !$0.isDeleted }
    }

    public func element(_ id: String) -> Element? {
        elements.first { $0["id"] as? String == id }.map(Element.init(raw:))
    }

    public func children(ofFrame id: String) -> [Element] {
        liveElements.filter { $0.frameId == id }
    }

    /// Inserts an element. `position` is the position in the full order (nil = top); a scene with `index` generates an index inserted between the two.
    public mutating func insert(_ element: Element, at position: Int? = nil) {
        edit { $0.insert(element, at: position) }
    }

    /// Modifies a single element; increments `version`, redraws `versionNonce` and updates `updated` only when content changed. Returns whether it changed.
    @discardableResult
    public mutating func mutate(_ id: String, _ body: (inout Element) -> Void) -> Bool {
        edit { $0.update(id, body) }
    }

    public mutating func delete(_ ids: Set<String>) {
        edit { $0.delete(ids) }
    }

    public mutating func move(_ ids: Set<String>, dx: Double, dy: Double) {
        edit { $0.move(ids, dx: dx, dy: dy) }
    }

    /// Scales to `rect` (the unrotated bounding box); `original` = the element when scaling began, from which every frame during the drag is computed
    public mutating func resize(_ id: String, to rect: CGRect, from original: Element? = nil) {
        edit { $0.resize(id, to: rect, from: original) }
    }

    public mutating func setFrame(_ ids: Set<String>, to frameID: String?) {
        edit { $0.setFrame(ids, to: frameID) }
    }

    public mutating func setText(_ id: String, to text: String) {
        edit { $0.setText(id, to: text) }
    }

    @discardableResult
    public mutating func addBoundText(_ text: String, to containerID: String) -> String? {
        edit { $0.addBoundText(text, to: containerID) }
    }

    @discardableResult
    public mutating func bind(arrow: String, _ end: ArrowEnd, to shape: String,
                              fixedPoint: CGPoint? = nil, gap: Double = 5) -> Bool {
        edit { $0.bind(arrow, end, to: shape, fixedPoint: fixedPoint, gap: gap) }
    }

    public mutating func unbind(arrow: String, _ end: ArrowEnd) {
        edit { $0.unbind(arrow, end) }
    }

    /// Called after shapes move or resize: arrows bound to `movedIDs` recompute their endpoints
    public mutating func rebindArrows(movedIDs: Set<String>) {
        edit { $0.rebindArrows(movedIDs: movedIDs) }
    }

    /// Loads the editing area, modifies, writes back; elements not touched keep their original dictionaries
    mutating func edit<T>(_ body: (inout SceneEditor) -> T) -> T {
        var editor = SceneEditor(elements.map(Element.init(raw:)))
        let result = body(&editor)
        raw["elements"] = editor.elements.map(\.raw)
        return result
    }
}
