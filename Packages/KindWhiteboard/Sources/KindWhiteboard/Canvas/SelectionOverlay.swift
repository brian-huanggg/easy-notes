import CoreGraphics
import QuartzCore

/// 選取外框、控制點、框選範圍與箭頭綁定目標（含 4 個連接點）的提示。以螢幕座標繪製（宿主給畫布 → 螢幕的轉換），
/// 所以控制點大小不隨縮放改變；放在 PencilKit 上方。iOS / macOS 共用。
@MainActor
final class SelectionOverlay {
    let root: CALayer = PlainLayer()

    private let outline = ShapeLayer()
    private let handles = ShapeLayer()
    private let marquee = ShapeLayer()
    private let bindTarget = ShapeLayer()
    private let connectors = ShapeLayer()
    private let snappedConnector = ShapeLayer()

    /// Excalidraw 的選取色
    static let accent = SceneColor.rgb(0x6965db)
    static let handleSize: CGFloat = 9
    /// 連接點的直徑（吸附中的那個放大）
    static let connectorSize: CGFloat = 8
    static let snappedConnectorSize: CGFloat = 12

    init() {
        root.anchorPoint = .zero
        for layer in [bindTarget, outline, marquee, handles, connectors, snappedConnector] { root.addSublayer(layer) }
        outline.fillColor = nil
        outline.strokeColor = Self.accent
        outline.lineWidth = 1
        handles.fillColor = SceneColor.rgb(0xffffff)
        handles.strokeColor = Self.accent
        handles.lineWidth = 1.5
        marquee.fillColor = SceneColor.rgb(0x6965db, alpha: 0.08)
        marquee.strokeColor = Self.accent
        marquee.lineWidth = 1
        marquee.lineDashPattern = [4, 4]
        bindTarget.fillColor = nil
        bindTarget.strokeColor = SceneColor.rgb(0x6965db, alpha: 0.6)
        bindTarget.lineWidth = 4
        connectors.fillColor = SceneColor.rgb(0xffffff)
        connectors.strokeColor = Self.accent
        connectors.lineWidth = 1.5
        snappedConnector.fillColor = Self.accent
        snappedConnector.strokeColor = SceneColor.rgb(0xffffff)
        snappedConnector.lineWidth = 2
    }

    /// `transform`：畫布座標 → 螢幕座標
    func update(_ editor: BoardEditor, transform: CGAffineTransform) {
        let frame = editor.selectionFrame
        let points = editor.handles

        let box = CGMutablePath()
        if let frame, !points.contains(where: { if case .end = $0.handle { true } else { false } }) {
            let rotate = CGAffineTransform(translationX: frame.center.x, y: frame.center.y)
                .rotated(by: frame.angle).translatedBy(x: -frame.center.x, y: -frame.center.y)
            box.addPath(CGPath(rect: frame.rect, transform: nil), transform: rotate.concatenating(transform))
        }
        outline.path = box

        let dots = CGMutablePath()
        let s = Self.handleSize
        for (handle, point) in points {
            let p = point.applying(transform)
            let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            if case .end = handle { dots.addEllipse(in: r.insetBy(dx: -1, dy: -1)) } else { dots.addRect(r) }
        }
        handles.path = dots

        if let lasso = editor.lasso, lasso.count > 1 {
            let path = CGMutablePath()
            path.addLines(between: lasso.map { $0.applying(transform) })
            path.closeSubpath()
            marquee.path = path
        } else {
            marquee.path = editor.marquee.map { CGPath(rect: $0.applying(transform), transform: nil) }
        }

        if let pick = editor.bindTarget, let el = editor.document.scene.element(pick.id) {
            let path = el.type == .text || el.type == .image
                ? CGPath(rect: el.rect.standardized, transform: nil) : ElementGeometry.outline(el)
            let t = ElementGeometry.rotation(el).concatenating(transform)
            bindTarget.path = path.copy(using: [t])
            let dots = CGMutablePath(), snapped = CGMutablePath()
            for (i, side) in Geometry.sides.enumerated() {
                let p = Geometry.point(in: el, ratio: side.ratio).applying(transform)
                let d = i == pick.side ? Self.snappedConnectorSize : Self.connectorSize
                let r = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
                if i == pick.side { snapped.addEllipse(in: r) } else { dots.addEllipse(in: r) }
            }
            connectors.path = dots
            snappedConnector.path = snapped
        } else {
            bindTarget.path = nil
            connectors.path = nil
            snappedConnector.path = nil
        }
    }
}

private extension CGPath {
    func copy(using transforms: [CGAffineTransform]) -> CGPath? {
        var t = transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
        return copy(using: &t)
    }
}
