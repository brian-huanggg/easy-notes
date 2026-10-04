import CoreGraphics
import ExcalidrawKit
import Foundation

/// 工具列插入（見 architecture/whiteboard.md「工具列改版」）：形狀、便條紙、文字框插在畫面中央，先離開手寫模式。
/// 尺寸是螢幕點（除以縮放倍率），不論縮放多少，插入後在畫面上一樣大。
extension BoardEditor {
    static let shapeSize: CGFloat = 160
    static let arrowLength: CGFloat = 200
    static let frameSize = CGSize(width: 400, height: 300)
    static let stickySize: CGFloat = 200
    static let noteCardSize = CGSize(width: 280, height: 160)
    /// 中央已有同位置的元素時往右下錯開
    static let insertOffset: CGFloat = 20

    private var viewCenter: CGPoint {
        visibleRect.isNull ? .zero : CGPoint(x: visibleRect.midX, y: visibleRect.midY)
    }

    /// 插入形狀，選取它（一筆 Undo）
    func insert(_ shape: BoardShape) {
        var el = Self.make(shape, box: insertionBox(size(of: shape)))
        // 矩形 / 圓角矩形是面板上明確選的，不套用上次的圓角
        applyCurrentStyle(to: &el, except: [.rounded])
        inking = false
        tool = .select
        operation(shape.title, select: { [el.id] }) { $0.insert(el) }
    }

    /// 插入便條紙並直接編輯其中的文字（插入與文字各一筆 Undo）
    func insertStickyNote() {
        let r = insertionBox(CGSize(width: Self.stickySize / zoom, height: Self.stickySize / zoom))
        let el = Element.stickyNote(x: r.minX, y: r.minY, size: r.width)
        inking = false
        tool = .select
        operation(L("便條紙"), select: { [el.id] }) { $0.insert(el) }
        editText(of: el.id)
    }

    /// 插入指向 Vault 檔案 `path` 的筆記卡片，選取它（一筆 Undo）
    func insertNoteCard(path: String) {
        let z = max(zoom, 0.01)
        let box = insertionBox(CGSize(width: Self.noteCardSize.width / z, height: Self.noteCardSize.height / z))
        inking = false
        tool = .select
        operation(L("筆記卡片"), select: { (id: String) in [id] }) { $0.insertNoteCard(path: path, in: box) }
        Task { await document.refreshCardPreviews(only: [path]) }
    }

    /// 在畫面中央開始一段新文字
    func insertText() {
        if textEditing != nil { finishTextEditing() }
        inking = false
        tool = .select
        let c = viewCenter
        newText(at: CGPoint(x: c.x - Self.defaultFontSize * 2, y: c.y))
    }

    // MARK: 計算

    private func size(of shape: BoardShape) -> CGSize {
        let z = max(zoom, 0.01)
        switch shape {
        case .arrow: return CGSize(width: Self.arrowLength / z, height: 0)
        case .frame: return CGSize(width: Self.frameSize.width / z, height: Self.frameSize.height / z)
        default: return CGSize(width: Self.shapeSize / z, height: Self.shapeSize / z)
        }
    }

    /// 以畫面中央為中心的範圍；同一處已有元素（例如連按兩次）就往右下錯開
    func insertionBox(_ size: CGSize) -> CGRect {
        let c = viewCenter
        var r = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        let step = Self.insertOffset / max(zoom, 0.01)
        let origins = document.scene.liveElements.map { CGPoint(x: $0.x, y: $0.y) }
        for _ in 0..<50 where origins.contains(where: { abs($0.x - r.minX) < 1 && abs($0.y - r.minY) < 1 }) {
            r = r.offsetBy(dx: step, dy: step)
        }
        return r
    }

    static func make(_ shape: BoardShape, box r: CGRect) -> Element {
        switch shape {
        case .rectangle: .rectangle(x: r.minX, y: r.minY, width: r.width, height: r.height, rounded: false)
        case .roundedRectangle: .rectangle(x: r.minX, y: r.minY, width: r.width, height: r.height)
        case .ellipse: .ellipse(x: r.minX, y: r.minY, width: r.width, height: r.height)
        case .diamond: .diamond(x: r.minX, y: r.minY, width: r.width, height: r.height)
        case .arrow: .arrow(from: CGPoint(x: r.minX, y: r.midY), to: CGPoint(x: r.maxX, y: r.midY))
        case .frame: .frame(x: r.minX, y: r.minY, width: r.width, height: r.height)
        }
    }
}
