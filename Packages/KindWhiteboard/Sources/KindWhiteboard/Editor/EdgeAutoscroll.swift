import CoreGraphics

/// 拖曳到畫面邊緣時自動捲動（見 architecture/whiteboard.md「4c：Mac 自動捲動與拖放圖片」）。平台無關：
/// 宿主每一幀以游標的螢幕位置問 `velocity`，平移畫面後再把同一個螢幕位置換成畫布座標交給編輯器。
enum EdgeAutoscroll {
    /// 距離邊緣多近開始捲動（螢幕點）
    static let inset: CGFloat = 32
    /// 最快的速度（螢幕點 / 秒）：游標到達邊緣或跑出畫面
    static let maxSpeed: CGFloat = 900

    /// 畫面要往哪個方向捲（螢幕點 / 秒；正 x = 往右看更多、正 y = 往下看更多）。
    /// 越靠近邊緣越快，到邊緣（或在畫面外）是最快；中間區域為零
    static func velocity(for p: CGPoint, in bounds: CGRect) -> CGVector {
        guard bounds.width > inset * 2, bounds.height > inset * 2 else { return .zero }
        func axis(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            if v < lo + inset { return -maxSpeed * min(1, (lo + inset - v) / inset) }
            if v > hi - inset { return maxSpeed * min(1, (v - (hi - inset)) / inset) }
            return 0
        }
        return CGVector(dx: axis(p.x, bounds.minX, bounds.maxX), dy: axis(p.y, bounds.minY, bounds.maxY))
    }
}
