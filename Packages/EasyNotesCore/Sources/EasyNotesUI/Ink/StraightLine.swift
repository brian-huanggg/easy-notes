import CoreGraphics
import Foundation

/// The geometry and detection of "hold to straighten" (platform-independent, unit-testable; iOS touch handling is in `StraightLineAssist`).
/// See "Ink toolbar" in architecture/ui.md
public enum StraightLine {
    /// How long the pen tip must hold still before it becomes a straight line (seconds)
    public static let holdDuration: TimeInterval = 0.5
    /// The wobble allowed while holding (screen points)
    public static let holdTolerance: CGFloat = 3
    /// A stroke must be at least this long (screen points) to become a straight line: a tap-and-hold does not count
    public static let minimumLength: CGFloat = 12
    /// The angle (degrees) at which it snaps when near horizontal, vertical or 45°
    public static let snapDegrees: CGFloat = 3

    /// The end point: when the angle is near a multiple of 45° it snaps to that direction (length unchanged)
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

    /// Points along the line (including both ends), with adjacent points no more than `spacing` apart
    public static func samples(from start: CGPoint, to end: CGPoint, spacing: CGFloat) -> [CGPoint] {
        let length = hypot(end.x - start.x, end.y - start.y)
        let count = max(Int((length / max(spacing, 0.01)).rounded(.up)), 1)
        return (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }
}

/// Decides whether the pen tip is holding: moving beyond the tolerance restarts the timer; the accumulated length must be enough to count. Coordinates are screen points
public struct HoldDetector: Sendable {
    /// The position where holding started (moving beyond the tolerance replaces it with the new position)
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

    /// Returns true = the hold timer restarted (the host must reschedule its timer)
    @discardableResult
    public mutating func move(to p: CGPoint, time: TimeInterval) -> Bool {
        length += hypot(p.x - last.x, p.y - last.y)
        last = p
        guard hypot(p.x - anchor.x, p.y - anchor.y) > StraightLine.holdTolerance else { return false }
        anchor = p
        anchorTime = time
        return true
    }

    /// Whether it has held long enough up to `time` and the stroke is long enough
    public func isHolding(at time: TimeInterval) -> Bool {
        length >= StraightLine.minimumLength && time - anchorTime >= StraightLine.holdDuration - 0.001
    }
}
