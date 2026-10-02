import CoreGraphics
import Foundation

/// 場景的型別化編輯 API。底層仍是原始 JSON 字典；每個會修改元素的操作都走
/// `SceneEditor.update`，所以 `version` / `versionNonce` / `updated` 的遞增只有一條路徑。
extension ExcalidrawScene {
    /// 包含已刪除（墓碑）的所有元素，依渲染順序（有 `index` 就依它，否則依陣列順序）
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

    /// 插入元素。`position` 是完整順序中的位置（nil = 最上層）；有 `index` 的場景會產生插在兩者之間的 index。
    public mutating func insert(_ element: Element, at position: Int? = nil) {
        edit { $0.insert(element, at: position) }
    }

    /// 修改單一元素；內容有變才遞增 `version`、重抽 `versionNonce`、更新 `updated`。回傳是否有變。
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

    public mutating func resize(_ id: String, to rect: CGRect) {
        edit { $0.resize(id, to: rect) }
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

    /// 形狀移動、縮放之後呼叫：綁在 `movedIDs` 上的箭頭重算端點
    public mutating func rebindArrows(movedIDs: Set<String>) {
        edit { $0.rebindArrows(movedIDs: movedIDs) }
    }

    /// 載入編輯區、修改、寫回；沒有被碰到的元素維持原本的字典
    mutating func edit<T>(_ body: (inout SceneEditor) -> T) -> T {
        var editor = SceneEditor(elements.map(Element.init(raw:)))
        let result = body(&editor)
        raw["elements"] = editor.elements.map(\.raw)
        return result
    }
}
