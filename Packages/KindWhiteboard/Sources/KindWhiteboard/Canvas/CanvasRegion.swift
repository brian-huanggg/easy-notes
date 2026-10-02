import CoreGraphics

/// 無限畫布的捲動範圍。Excalidraw 的座標可以是負數，`PKCanvasView` 的內容座標從 0 開始，
/// 所以 `內容座標 = 場景座標 − origin`。範圍 = 內容外擴一圈留白，捲到接近邊緣時擴大；
/// 往左 / 上擴大時 origin 變小，宿主要把筆畫與 `contentOffset` 平移同樣的量。
struct CanvasRegion: Equatable {
    /// 留白：大於最小縮放（0.25×）時 iPad 最大螢幕看到的範圍，縮到最小也碰不到邊
    static let margin: CGFloat = 6_000
    /// 範圍對齊到這個倍數：平移筆畫的量是整數，來回轉換不會累積誤差
    static let step: CGFloat = 1_000

    var rect: CGRect

    /// 內容座標 (0, 0) 的場景座標
    var origin: CGPoint { rect.origin }
    var size: CGSize { rect.size }

    /// 涵蓋 `content`（場景座標，nil = 空白板）的範圍
    init(covering content: CGRect?) {
        rect = Self.snap((content ?? CGRect(x: 0, y: 0, width: 1, height: 1)).insetBy(dx: -Self.margin, dy: -Self.margin))
    }

    /// `visible`（場景座標）離邊緣不到半個留白時，回傳擴大後的範圍；不需要擴大回傳 nil
    func expanded(toShow visible: CGRect) -> CanvasRegion? {
        guard !rect.insetBy(dx: Self.margin / 2, dy: Self.margin / 2).contains(visible) else { return nil }
        var next = self
        next.rect = Self.snap(rect.union(visible.insetBy(dx: -Self.margin, dy: -Self.margin)))
        return next == self ? nil : next
    }

    /// 涵蓋 `content` 的範圍（例如外部加入了範圍外的元素）；已涵蓋回傳 nil
    func expanded(toInclude content: CGRect) -> CanvasRegion? {
        guard !rect.contains(content) else { return nil }
        var next = self
        next.rect = Self.snap(rect.union(content.insetBy(dx: -Self.margin, dy: -Self.margin)))
        return next
    }

    func toContent(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
    func toScene(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y) }

    private static func snap(_ r: CGRect) -> CGRect {
        let minX = (r.minX / step).rounded(.down) * step, minY = (r.minY / step).rounded(.down) * step
        let maxX = (r.maxX / step).rounded(.up) * step, maxY = (r.maxY / step).rounded(.up) * step
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
