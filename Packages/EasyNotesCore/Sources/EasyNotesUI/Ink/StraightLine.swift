import CoreGraphics
import Foundation

/// 「停住變直線」的幾何與判定（平台無關，可單元測試；iOS 的觸控處理在 `StraightLineAssist`）。
/// 見 architecture/ui.md「手寫工具列」
public enum StraightLine {
    /// 筆尖停住多久才變直線（秒）
    public static let holdDuration: TimeInterval = 0.5
    /// 停住時允許的晃動（螢幕點）
    public static let holdTolerance: CGFloat = 3
    /// 筆畫至少要這麼長（螢幕點）才會變直線：點一下停住不算
    public static let minimumLength: CGFloat = 12
    /// 接近水平、垂直或 45° 時吸附的角度（度）
    public static let snapDegrees: CGFloat = 3

    /// 終點：角度接近 45° 的倍數時吸附到那個方向（長度不變）
    public static func snapped(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let nearest = (angle / step).rounded() * step
        guard abs(angle - nearest) <= snapDegrees * .pi / 180 else { return end }
        return CGPoint(x: start.x + cos(nearest) * length, y: start.y + sin(nearest) * length)
    }

    /// 沿線取點（含兩端），相鄰兩點距離不超過 `spacing`
    public static func samples(from start: CGPoint, to end: CGPoint, spacing: CGFloat) -> [CGPoint] {
        let length = hypot(end.x - start.x, end.y - start.y)
        let count = max(Int((length / max(spacing, 0.01)).rounded(.up)), 1)
        return (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }
}

/// 判斷筆尖是否停住：移動超過容差就重新計時；累計長度夠才算數。座標是螢幕點
public struct HoldDetector: Sendable {
    /// 這個位置開始停住（移動超過容差就換成新的位置）
    public private(set) var anchor: CGPoint = .zero
    public private(set) var anchorTime: TimeInterval = 0
    public private(set) var length: CGFloat = 0
    private var last: CGPoint = .zero

    public init() {}

    public mutating func begin(at p: CGPoint, time: TimeInterval) {
        anchor = p
        anchorTime = time
        last = p
        length = 0
    }

    /// 回傳 true = 停住的計時重新開始（宿主要重排計時器）
    @discardableResult
    public mutating func move(to p: CGPoint, time: TimeInterval) -> Bool {
        length += hypot(p.x - last.x, p.y - last.y)
        last = p
        guard hypot(p.x - anchor.x, p.y - anchor.y) > StraightLine.holdTolerance else { return false }
        anchor = p
        anchorTime = time
        return true
    }

    /// 到 `time` 為止是否已停住夠久，且筆畫夠長
    public func isHolding(at time: TimeInterval) -> Bool {
        length >= StraightLine.minimumLength && time - anchorTime >= StraightLine.holdDuration - 0.001
    }
}
