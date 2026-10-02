import CoreGraphics
import QuartzCore

/// 編輯器的畫布背景：網格或點（見 Architecture「工具列改版」）。放在結構層底下、跟著同一個 transform
/// （畫布座標）。用兩層 `CAReplicatorLayer` 複製一個點或一條線，只涵蓋畫面範圍；
/// 間距是 20 的 2ⁿ 倍（螢幕上至少約 14 點），點的大小與線寬除以縮放倍率，螢幕上固定。iOS / macOS 共用。
@MainActor
final class BackgroundPattern {
    let root: CALayer = PlainLayer()

    /// 點：rows 複製 columns、columns 複製 dot
    private let rows = Replicator()
    private let columns = Replicator()
    private let dot = PlainLayer()
    /// 網格：直線往右複製、橫線往下複製
    private let verticals = Replicator()
    private let vertical = PlainLayer()
    private let horizontals = Replicator()
    private let horizontal = PlainLayer()

    private(set) var style: BoardBackground = .none
    private var last: (rect: CGRect, zoom: CGFloat)?

    static let baseSpacing: CGFloat = 20
    static let minScreenSpacing: CGFloat = 14
    static let dotDiameter: CGFloat = 2.5
    static let lineWidth: CGFloat = 0.75

    init() {
        root.anchorPoint = .zero
        for layer in [rows, verticals, horizontals] { root.addSublayer(layer) }
        rows.addSublayer(columns)
        columns.addSublayer(dot)
        verticals.addSublayer(vertical)
        horizontals.addSublayer(horizontal)
        dot.backgroundColor = SceneColor.rgb(0xc4c4c8)
        vertical.backgroundColor = SceneColor.rgb(0x000000, alpha: 0.07)
        horizontal.backgroundColor = vertical.backgroundColor
        for layer in [rows, columns, verticals, horizontals] { layer.anchorPoint = .zero }
        apply(.none)
    }

    func apply(_ next: BoardBackground) {
        style = next
        rows.isHidden = next != .dots
        verticals.isHidden = next != .grid
        horizontals.isHidden = next != .grid
        last = nil
    }

    /// 畫面範圍（畫布座標）或縮放改變時呼叫（捲動中逐幀）
    func update(visible: CGRect, zoom: CGFloat) {
        guard style != .none, !visible.isNull, visible.width > 0, zoom > 0 else { return }
        var spacing = Self.baseSpacing
        while spacing * zoom < Self.minScreenSpacing { spacing *= 2 }
        let x0 = (visible.minX / spacing).rounded(.down) * spacing
        let y0 = (visible.minY / spacing).rounded(.down) * spacing
        let nx = Int(((visible.maxX - x0) / spacing).rounded(.up)) + 1
        let ny = Int(((visible.maxY - y0) / spacing).rounded(.up)) + 1
        let rect = CGRect(x: x0, y: y0, width: CGFloat(nx) * spacing, height: CGFloat(ny) * spacing)
        if let last, last.rect == rect, last.zoom == zoom { return }
        last = (rect, zoom)

        switch style {
        case .dots:
            let d = Self.dotDiameter / zoom
            rows.position = rect.origin
            rows.instanceCount = ny
            rows.instanceTransform = CATransform3DMakeTranslation(0, spacing, 0)
            columns.instanceCount = nx
            columns.instanceTransform = CATransform3DMakeTranslation(spacing, 0, 0)
            dot.frame = CGRect(x: -d / 2, y: -d / 2, width: d, height: d)
            dot.cornerRadius = d / 2
        case .grid:
            let w = Self.lineWidth / zoom
            verticals.position = rect.origin
            verticals.instanceCount = nx
            verticals.instanceTransform = CATransform3DMakeTranslation(spacing, 0, 0)
            vertical.frame = CGRect(x: -w / 2, y: 0, width: w, height: rect.height)
            horizontals.position = rect.origin
            horizontals.instanceCount = ny
            horizontals.instanceTransform = CATransform3DMakeTranslation(0, spacing, 0)
            horizontal.frame = CGRect(x: 0, y: -w / 2, width: rect.width, height: w)
        case .none:
            break
        }
    }
}

private final class Replicator: CAReplicatorLayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}
