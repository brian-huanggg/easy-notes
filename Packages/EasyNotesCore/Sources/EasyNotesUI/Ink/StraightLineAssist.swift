#if os(iOS)
import PencilKit
import UIKit

extension InkToolSpec {
    /// 換成 PencilKit 的工具；粗細 = 墨水 / 橡皮擦的 `defaultWidth` × 倍數，夾在 `validWidthRange` 內
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
    /// `#rrggbb`（畫布固定淺色，顏色不隨深色模式反轉）
    convenience init(inkHex hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits.prefix(6), radix: 16) ?? 0x1e1e1e
        self.init(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

/// 「停住變直線」（Apple 備忘錄 / GoodNotes 式，見 architecture/ui.md「手寫工具列」）：畫一筆後筆尖停住，
/// 這一筆變成起點到目前位置的直線；不放開筆可以繼續調整終點。每個 `PKCanvasView` 掛一個。
///
/// 調整期間 `drawing` 的變動不該寫回（宿主檢查 `isAdjusting`）；放開時加進直線的那一次變動才寫回。
@MainActor
public final class StraightLineAssist: NSObject, UIGestureRecognizerDelegate {
    /// 調整直線中：宿主的 `canvasViewDrawingDidChange` 不寫回
    public private(set) var isAdjusting = false

    private weak var canvas: PKCanvasView?
    private let observer = TouchObserver()
    private var detector = HoldDetector()
    private var timer: Timer?
    /// 開始畫這一筆時的筆畫（取消 PencilKit 進行中的筆畫後以它為準）
    private var snapshot: PKDrawing?
    /// 畫布座標（`PKCanvasView` 的 bounds 座標，含縮放）
    private var start: CGPoint = .zero
    private var end: CGPoint = .zero
    private var tool: PKInkingTool?
    private let preview = CAShapeLayer()
    /// 調整期間停用的手勢與它們原本的狀態
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

    // MARK: 觸控

    /// 只看 `drawingPolicy` 允許書寫的觸控，且畫布正在用畫筆 / 螢光筆
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
            // 筆畫已被取消：維持開始時的內容
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

    // MARK: 調整

    private func beginAdjusting() {
        guard let canvas, let snapshot else { return }
        isAdjusting = true
        // 停用再開啟會取消 PencilKit 進行中的筆畫；放開前保持停用，避免 PencilKit 從目前的觸控重新起筆。
        // 捲動也先停用（PencilKit 不畫之後，Pencil 的移動可能變成捲動）
        suspended = [canvas.drawingGestureRecognizer, canvas.panGestureRecognizer].filter(\.isEnabled)
        suspended.forEach { $0.isEnabled = false }
        // 取消後 PencilKit 仍留下這一筆時，換回開始時的內容
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

    /// 放開：把直線加進開始時的內容（同一種墨水、顏色與粗細），註冊一筆 Undo
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
        isAdjusting = false // 這一次變動要寫回
        Self.set(next, previous: before, on: canvas)
    }

    /// 設定筆畫並在畫布的 undoManager 註冊反向操作（白板與筆畫共用那個堆疊；PDF 的是私有的，由模型 Undo 負責）
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

    /// 只觀察：與所有手勢同時辨識，不影響書寫、捲動與點選
    public func gestureRecognizer(_ g: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// 只觀察觸控、永遠不辨識的手勢（追蹤第一個可書寫的觸控）
private final class TouchObserver: UIGestureRecognizer {
    weak var assist: StraightLineAssist?
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if tracked == nil, assist?.shouldTrack(touch) == true {
                tracked = touch
                assist?.began(touch)
            } else if tracked != nil, assist?.isAdjusting != true {
                // 第二根手指（捲動、縮放）：這一筆不變直線
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
    /// 還沒開始調整就放棄追蹤（例如第二根手指）
    fileprivate func cancelledTracking() {
        guard !isAdjusting else { return }
        cancelled()
    }
}

/// Pencil 點兩下（取代 `PKToolPicker` 原本的行為）：依系統設定切換橡皮擦 / 上一個工具，或收起 / 叫回選項膠囊
@MainActor
public final class InkPencilInteraction: NSObject, UIPencilInteractionDelegate {
    public let interaction = UIPencilInteraction()
    private let isActive: () -> Bool

    /// `isActive`：是否在手寫模式（不在時點兩下不處理）
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
