import CoreGraphics

/// 頁面座標 ⇄ 顯示座標。標註存「未旋轉的 cropBox 頁面座標」：單位 PDF point、原點左上、y 向下；
/// 頁面的 `rotation`（順時針 0 / 90 / 180 / 270）只在顯示與匯出時套用。
public struct PDFPageGeometry: Equatable, Sendable {
    /// 未旋轉的 cropBox 尺寸
    public let size: CGSize
    /// 正規化到 0 / 90 / 180 / 270
    public let rotation: Int

    public init(cropBox: CGRect, rotation: Int) {
        self.init(size: cropBox.standardized.size, rotation: rotation)
    }

    public init(size: CGSize, rotation: Int) {
        self.size = size
        self.rotation = ((rotation % 360) + 360) % 360 / 90 * 90
    }

    /// 旋轉後（使用者看到的）頁面尺寸
    public var displaySize: CGSize {
        rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// 頁面座標 → 顯示座標（單位仍是 point，原點左上）
    public func toDisplay(_ p: CGPoint) -> CGPoint {
        switch rotation {
        case 90: CGPoint(x: size.height - p.y, y: p.x)
        case 180: CGPoint(x: size.width - p.x, y: size.height - p.y)
        case 270: CGPoint(x: p.y, y: size.width - p.x)
        default: p
        }
    }

    /// 顯示座標 → 頁面座標
    public func toPage(_ p: CGPoint) -> CGPoint {
        switch rotation {
        case 90: CGPoint(x: p.y, y: size.height - p.x)
        case 180: CGPoint(x: size.width - p.x, y: size.height - p.y)
        case 270: CGPoint(x: size.width - p.y, y: p.x)
        default: p
        }
    }

    /// 頁面座標的矩形 → 顯示座標的外框
    public func toDisplay(_ rect: CGRect) -> CGRect {
        let a = toDisplay(rect.origin), b = toDisplay(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 頁面座標 → 顯示座標的仿射變換，可直接 `concatenate` 到 `CGContext`
    public var displayTransform: CGAffineTransform {
        switch rotation {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        case 270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        default: .identity
        }
    }

    /// 頁面座標（左上、y 向下）→ PDF 使用者空間（左下、y 向上，原點含 cropBox 偏移）。匯出畫原頁面時用
    public func toPDFSpace(_ p: CGPoint, cropBox: CGRect) -> CGPoint {
        CGPoint(x: cropBox.minX + p.x, y: cropBox.maxY - p.y)
    }
}

#if canImport(PDFKit)
import PDFKit

extension PDFPageGeometry {
    public init(page: PDFPage) {
        self.init(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
    }
}
#endif
