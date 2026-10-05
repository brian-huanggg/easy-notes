#if os(iOS)
import PencilKit
import UIKit

extension InkToolSpec {
    /// Converts to a PencilKit tool; width = the ink / eraser's `defaultWidth` × multiplier, clamped to `validWidthRange`
    public var pkTool: PKTool {
        switch self {
        case let .ink(raw, color, scale):
            let type = PKInk.InkType(rawValue: raw) ?? .pen
            let range = type.validWidthRange
            let width = min(max(type.defaultWidth * scale, range.lowerBound), range.upperBound)
            return PKInkingTool(type, color: UIColor(inkHex: color), width: width)
        case let .eraser(partial, scale):
            guard partial else { return PKEraserTool(.vector) }
            let range = PKEraserTool.EraserType.bitmap.validWidthRange
            let width = min(max(PKEraserTool.EraserType.bitmap.defaultWidth * scale, range.lowerBound), range.upperBound)
            return PKEraserTool(.bitmap, width: width)
        case .lasso:
            return PKLassoTool()
        }
    }
}

extension UIColor {
    /// `#rrggbb` (the canvas is always light, so colors do not invert in dark mode)
    convenience init(inkHex hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits.prefix(6), radix: 16) ?? 0x1e1e1e
        self.init(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

/// "Hold to straighten" (Apple Notes / GoodNotes style, see "Ink toolbar" in architecture/ui.md): after drawing a stroke the pen tip holds still,
/// and the stroke becomes a straight line from the start to the current position; keep the pen down to keep adjusting the end point. One per `PKCanvasView`.
///
/// `drawing` changes during adjustment must not be written back (the host checks `isAdjusting`); only the change that adds the line on release is written back.
@MainActor
public final class StraightLineAssist: NSObject, UIGestureRecognizerDelegate {
    /// Adjusting a line: the host's `canvasViewDrawingDidChange` does not write back
    public private(set) var isAdjusting = false

    private weak var canvas: PKCanvasView?
    private let observer = TouchObserver()
    private var detector = HoldDetector()
    private var timer: Timer?
    /// The strokes when this stroke began (the reference after cancelling PencilKit's in-progress stroke)
    private var snapshot: PKDrawing?
    /// Canvas coordinates (`PKCanvasView` bounds coordinates, including zoom)
    private var start: CGPoint = .zero
    private var end: CGPoint = .zero
    private var tool: PKInkingTool?
    private let preview = CAShapeLayer()
    /// The gestures disabled during adjustment and their original states
    private var suspended: [UIGestureRecognizer] = []

    public init(canvas: PKCanvasView) {
        self.canvas = canvas
        super.init()
        observer.assist = self
        observer.delegate = self
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        canvas.addGestureRecognizer(observer)
        preview.lineCap = .round
        preview.fillColor = nil
        preview.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }

    // MARK: Touches

    /// Only touches the `drawingPolicy` allows to write, and only while the canvas is using the pen / highlighter
    fileprivate func shouldTrack(_ touch: UITouch) -> Bool {
        guard let canvas, canvas.drawingGestureRecognizer.isEnabled, canvas.isUserInteractionEnabled,
              canvas.tool is PKInkingTool else { return false }
        switch canvas.drawingPolicy {
        case .anyInput: return true
        case .pencilOnly: return touch.type == .pencil
        default: return touch.type == .pencil || !UIPencilInteraction.prefersPencilOnlyDrawing
        }
    }

    fileprivate func began(_ touch: UITouch) {
        guard let canvas else { return }
        snapshot = canvas.drawing
        tool = canvas.tool as? PKInkingTool
        start = touch.location(in: canvas)
        end = start
        detector.begin(at: touch.location(in: nil), time: touch.timestamp)
        scheduleTimer()
    }

    fileprivate func moved(_ touch: UITouch) {
        guard let canvas else { return }
        if isAdjusting {
            end = StraightLine.snapped(from: start, to: touch.location(in: canvas))
            updatePreview()
            return
        }
        end = touch.location(in: canvas)
        if detector.move(to: touch.location(in: nil), time: touch.timestamp) { scheduleTimer() }
    }

    fileprivate func ended() {
        timer?.invalidate()
        if isAdjusting { commit() }
        reset()
    }

    fileprivate func cancelled() {
        timer?.invalidate()
        if isAdjusting, let canvas, let snapshot {
            // The stroke was cancelled: keep the content from the start
            canvas.drawing = snapshot
        }
        reset()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: StraightLine.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func holdTimerFired() {
        guard !isAdjusting, snapshot != nil, detector.isHolding(at: ProcessInfo.processInfo.systemUptime) else { return }
        beginAdjusting()
    }

    // MARK: Adjusting

    private func beginAdjusting() {
        guard let canvas, let snapshot else { return }
        isAdjusting = true
        // Disabling and re-enabling cancels PencilKit's in-progress stroke; stay disabled until release so PencilKit does not start a new stroke from the current touch.
        // Scrolling is disabled first too (once PencilKit stops drawing, Pencil movement could turn into scrolling)
        suspended = [canvas.drawingGestureRecognizer, canvas.panGestureRecognizer].filter(\.isEnabled)
        suspended.forEach { $0.isEnabled = false }
        // When PencilKit still leaves the stroke after cancelling, restore the content from the start
        if canvas.drawing.strokes.count != snapshot.strokes.count { canvas.drawing = snapshot }
        end = StraightLine.snapped(from: start, to: end)
        preview.strokeColor = previewColor.cgColor
        canvas.layer.addSublayer(preview)
        updatePreview()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var previewColor: UIColor {
        guard let tool else { return .black }
        switch tool.inkType {
        case .marker: return tool.color.withAlphaComponent(0.4)
        case .pencil: return tool.color.withAlphaComponent(0.85)
        default: return tool.color
        }
    }

    private func updatePreview() {
        guard let canvas, let tool else { return }
        preview.frame = canvas.bounds
        preview.bounds = canvas.bounds
        preview.lineWidth = tool.width * canvas.zoomScale
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        preview.path = path
    }

    /// Release: adds the line to the starting content (same ink, color and width) and registers one Undo
    private func commit() {
        guard let canvas, let snapshot, let tool else { return }
        let zoom = max(canvas.zoomScale, 0.01)
        let a = CGPoint(x: start.x / zoom, y: start.y / zoom), b = CGPoint(x: end.x / zoom, y: end.y / zoom)
        guard hypot(b.x - a.x, b.y - a.y) > 0.5 else {
            canvas.drawing = snapshot
            return
        }
        let size = CGSize(width: tool.width, height: tool.width)
        let points = StraightLine.samples(from: a, to: b, spacing: 2).enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.004, size: size, opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(tool.inkType, color: tool.color),
                              path: PKStrokePath(controlPoints: points, creationDate: Date()))
        var next = snapshot
        next.strokes.append(stroke)
        let before = canvas.drawing
        isAdjusting = false // This change must be written back
        Self.set(next, previous: before, on: canvas)
    }

    /// Sets the strokes and registers the inverse on the canvas's undoManager (the whiteboard shares that stack with strokes; PDF's is private and the model Undo handles it)
    private static func set(_ drawing: PKDrawing, previous: PKDrawing, on canvas: PKCanvasView) {
        canvas.drawing = drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated { set(previous, previous: drawing, on: canvas) }
        }
    }

    private func reset() {
        preview.removeFromSuperlayer()
        suspended.forEach { $0.isEnabled = true }
        suspended = []
        isAdjusting = false
        snapshot = nil
        tool = nil
        timer = nil
    }

    // MARK: UIGestureRecognizerDelegate

    /// Observe only: recognized simultaneously with all gestures, without affecting writing, scrolling or tapping
    public func gestureRecognizer(_ g: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// A gesture that only observes touches and never recognizes (tracks the first writable touch)
private final class TouchObserver: UIGestureRecognizer {
    weak var assist: StraightLineAssist?
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if tracked == nil, assist?.shouldTrack(touch) == true {
                tracked = touch
                assist?.began(touch)
            } else if tracked != nil, assist?.isAdjusting != true {
                // A second finger (scroll, zoom): this stroke does not become a straight line
                assist?.cancelledTracking()
                tracked = nil
                state = .failed
                return
            } else {
                ignore(touch, for: event)
            }
        }
        if tracked == nil { state = .failed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        assist?.moved(tracked)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        assist?.moved(tracked)
        assist?.ended()
        self.tracked = nil
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        assist?.cancelled()
        self.tracked = nil
        state = .failed
    }

    override func reset() {
        super.reset()
        if tracked != nil {
            assist?.cancelled()
            tracked = nil
        }
    }
}

extension StraightLineAssist {
    /// Gives up tracking before adjustment starts (for example a second finger)
    fileprivate func cancelledTracking() {
        guard !isAdjusting else { return }
        cancelled()
    }
}

/// Pencil double-tap (replacing `PKToolPicker`'s original behavior): switches eraser / previous tool or collapses / restores the options capsule per system setting
@MainActor
public final class InkPencilInteraction: NSObject, UIPencilInteractionDelegate {
    public let interaction = UIPencilInteraction()
    private let isActive: () -> Bool

    /// `isActive`: whether in ink mode (a double-tap is not handled otherwise)
    public init(isActive: @escaping () -> Bool) {
        self.isActive = isActive
        super.init()
        interaction.delegate = self
    }

    public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard isActive() else { return }
        let action: PencilTapAction = switch UIPencilInteraction.preferredTapAction {
        case .switchEraser: .switchEraser
        case .switchPrevious: .switchPrevious
        case .showColorPalette, .showInkAttributes, .showContextualPalette: .toggleOptions
        default: .none
        }
        InkSettings.shared.pencilTap(action)
    }
}
#endif
