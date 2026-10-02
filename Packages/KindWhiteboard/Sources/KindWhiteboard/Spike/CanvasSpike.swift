#if os(iOS)
import PencilKit
import SwiftUI
import UIKit

/// Spike S3（見 Roadmap Phase 4）：驗證「layer 結構層在 `PKCanvasView` 底下」的畫布架構。
/// 只在 DEBUG 或啟動參數 `-WhiteboardSpike YES` 時註冊成側邊欄面板；不讀寫任何檔案。
/// 驗證項目：結構層與筆畫在平移縮放中對齊、縮放後是否清晰、1,000 個元素的幀率、手指 / Pencil 的手勢分工。
struct CanvasSpikeView: View {
    @State private var stats = SpikeStats()
    @State private var options = SpikeOptions()

    var body: some View {
        SpikeCanvasRepresentable(stats: stats, options: options)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .topLeading) { hud }
            .toolbar {
                ToolbarItemGroup {
                    Picker("工具", selection: $options.tool) {
                        Label("筆", systemImage: "pencil.tip").tag(SpikeOptions.Tool.pen)
                        Label("選取", systemImage: "cursorarrow").tag(SpikeOptions.Tool.select)
                    }
                    .pickerStyle(.segmented)
                    Menu {
                        Picker("元素數", selection: $options.count) {
                            ForEach([100, 1_000, 3_000, 10_000], id: \.self) { Text("\($0) 個元素").tag($0) }
                        }
                        Toggle("視窗裁切", isOn: $options.culling)
                        Toggle("縮放後重設 contentsScale", isOn: $options.rescale)
                        Toggle("隱藏結構層（只剩 PencilKit）", isOn: $options.hideStructure)
                        Toggle("縮放回彈", isOn: $options.bouncesZoom)
                    } label: {
                        Label("選項", systemImage: "slider.horizontal.3")
                    }
                }
            }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FPS \(stats.fps)　最長一幀 \(stats.worstFrameMS, format: .number.precision(.fractionLength(1))) ms")
            Text("layer \(stats.liveLayers) / \(options.count)　縮放 \(stats.zoom, format: .number.precision(.fractionLength(2)))×　raster \(stats.rasterScale, format: .number.precision(.fractionLength(1)))")
            Text("callback 最長 \(stats.worstCallbackMS, format: .number.precision(.fractionLength(1))) ms　待處理 \(stats.pendingWork)")
            Text("選取：\(stats.selected.map(String.init) ?? "—")")
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding()
        .allowsHitTesting(false)
    }
}

@Observable @MainActor
final class SpikeStats {
    var fps = 0
    var worstFrameMS = 0.0
    var liveLayers = 0
    var zoom = 1.0
    var rasterScale = 1.0
    var selected: Int?
    /// 一秒內 scroll / zoom callback 與分批工作在主執行緒花的最長時間
    var worstCallbackMS = 0.0
    var pendingWork = 0
}

@Observable @MainActor
final class SpikeOptions {
    enum Tool { case pen, select }
    var tool = Tool.pen
    var count = 1_000
    var culling = true
    var rescale = true
    /// 診斷用：移除結構層並停止同步，確認筆畫的縮放問題是否來自 PencilKit 本身
    var hideStructure = false
    /// 超過最小 / 最大縮放時的回彈。回彈動畫期間 scroll view 不會每幀呼叫 scrollViewDidZoom，
    /// 結構層直接跳到終點、筆畫還在動畫中，兩者對不上，所以預設關閉
    var bouncesZoom = false
}

private struct SpikeCanvasRepresentable: UIViewRepresentable {
    let stats: SpikeStats
    let options: SpikeOptions

    func makeUIView(context: Context) -> SpikeCanvas {
        SpikeCanvas(stats: stats)
    }

    func updateUIView(_ view: SpikeCanvas, context: Context) {
        view.apply(tool: options.tool, count: options.count, culling: options.culling, rescale: options.rescale,
                   hideStructure: options.hideStructure, bouncesZoom: options.bouncesZoom)
    }
}

/// 結構元素的最小模型（只為了 spike；正式模型在 4a 的 `Element`）
struct SpikeElement {
    enum Kind: CaseIterable { case rectangle, ellipse, arrow, text }
    let id: Int
    let kind: Kind
    /// 畫布座標；arrow 從 origin 指向 (maxX, maxY)，寬高可為負
    var frame: CGRect
    let color: UIColor
    let text: String

    var bounds: CGRect { frame.standardized }
}

// MARK: - 畫布

/// 下層：`structureHost` 的 `contentLayer` 以 transform 跟著 `PKCanvasView` 的 contentOffset / zoomScale。
/// 上層：透明的 `PKCanvasView`，負責手寫、捲動、縮放與所有觸控。
final class SpikeCanvas: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    static let canvasSize = CGSize(width: 8_000, height: 8_000)

    private let stats: SpikeStats
    private let structureHost = UIView()
    private let contentLayer = CALayer()
    private let canvas = PKCanvasView()
    private let toolPicker = PKToolPicker()
    private let drag = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()

    private var elements: [SpikeElement] = []
    private var layers: [Int: CALayer] = [:]
    private var tool = SpikeOptions.Tool.pen
    private var count = 0
    private var culling = true
    private var rescale = true
    private var hideStructure = false
    private var rasterScale: CGFloat = 1
    private var selected: Int?
    private var dragOffset = CGSize.zero
    /// 縮放中主執行緒卡一幀，PencilKit 的點陣與 scroll view 的 transform 就會短暫對不上（筆畫縮小又回彈），
    /// 所以建立 layer 與重新點陣化都分批，每幀有上限
    private static let layersPerFrame = 120
    private var needsMoreLayers = false
    private var rasterQueue: [CALayer] = []
    private var worstCallback: CFTimeInterval = 0

    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var windowStart: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var worstFrame: CFTimeInterval = 0

    init(stats: SpikeStats) {
        self.stats = stats
        super.init(frame: .zero)
        backgroundColor = .systemBackground

        structureHost.isUserInteractionEnabled = false
        structureHost.layer.addSublayer(contentLayer)
        contentLayer.anchorPoint = .zero
        contentLayer.frame = CGRect(origin: .zero, size: Self.canvasSize)
        addSubview(structureHost)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.contentSize = Self.canvasSize
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 4
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput // 模擬器沒有 Pencil
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        addSubview(canvas)

        // 拖曳元素：開始後會阻止 scroll view 的平移。筆模式要長按才開始（手指以捲動為主），選取模式碰到就開始
        drag.delegate = self
        drag.addTarget(self, action: #selector(handleDrag(_:)))
        canvas.addGestureRecognizer(drag)
        // 點一下：選取元素，點空白處取消選取；不影響捲動
        tap.addTarget(self, action: #selector(handleTap(_:)))
        canvas.addGestureRecognizer(tap)

        toolPicker.addObserver(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        structureHost.frame = bounds
        canvas.frame = bounds
        if canvas.contentOffset == .zero, bounds.width > 0 {
            canvas.contentOffset = CGPoint(x: (Self.canvasSize.width - bounds.width) / 2,
                                           y: (Self.canvasSize.height - bounds.height) / 2)
        }
        syncTransform()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
            toolPicker.setVisible(tool == .pen, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    func apply(tool: SpikeOptions.Tool, count: Int, culling: Bool, rescale: Bool, hideStructure: Bool,
               bouncesZoom: Bool) {
        canvas.bouncesZoom = bouncesZoom
        if hideStructure != self.hideStructure {
            self.hideStructure = hideStructure
            structureHost.isHidden = hideStructure
            drag.isEnabled = !hideStructure
            tap.isEnabled = !hideStructure
            if !hideStructure { // 隱藏期間沒有同步，恢復時補上
                syncTransform()
                updateVisibleLayers()
            }
        }
        if tool != self.tool {
            self.tool = tool
            // 選取模式：關掉 PencilKit 的手勢，Pencil 與手指都交給 drag
            canvas.drawingGestureRecognizer.isEnabled = tool == .pen
            toolPicker.setVisible(tool == .pen, forFirstResponder: canvas)
        }
        let touchTypes = tool == .pen
            ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        drag.allowedTouchTypes = touchTypes
        tap.allowedTouchTypes = touchTypes
        drag.minimumPressDuration = tool == .pen ? 0.35 : 0

        var rebuild = false
        if count != self.count { self.count = count; generate(); rebuild = true }
        if culling != self.culling { self.culling = culling; rebuild = true }
        if rescale != self.rescale {
            self.rescale = rescale
            rasterScale = targetRaster
            rebuild = true
        }
        if rebuild {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layers.values.forEach { $0.removeFromSuperlayer() }
            layers.removeAll()
            CATransaction.commit()
            updateVisibleLayers()
        }
    }

    // MARK: 元素

    private func generate() {
        var rng = SplitMix64(seed: 42)
        let colors: [UIColor] = [.systemBlue, .systemRed, .systemGreen, .systemOrange, .systemPurple, .label]
        let words = ["光合作用", "粒線體", "Excalidraw", "注音輸入", "白板", "箭頭綁定", "frame", "細胞"]
        elements = (0..<count).map { i in
            let kind = SpikeElement.Kind.allCases[Int(rng.next() % 4)]
            let x = CGFloat(rng.unit()) * (Self.canvasSize.width - 300) + 50
            let y = CGFloat(rng.unit()) * (Self.canvasSize.height - 300) + 50
            let w = CGFloat(rng.unit()) * 160 + 40
            let h = CGFloat(rng.unit()) * 120 + 30
            let frame = switch kind {
            case .arrow: CGRect(x: x, y: y, width: rng.unit() > 0.5 ? w : -w, height: rng.unit() > 0.5 ? h : -h)
            case .text: CGRect(x: x, y: y, width: 160, height: 28)
            default: CGRect(x: x, y: y, width: w, height: h)
            }
            return SpikeElement(id: i, kind: kind, frame: frame, color: colors[Int(rng.next() % 6)],
                                text: words[Int(rng.next() % UInt64(words.count))])
        }
        selected = nil
        stats.selected = nil
    }

    private func makeLayer(_ el: SpikeElement) -> CALayer {
        let b = el.bounds
        let layer: CALayer
        switch el.kind {
        case .text:
            let text = CATextLayer()
            text.string = el.text
            text.font = UIFont.systemFont(ofSize: 20)
            text.fontSize = 20
            text.foregroundColor = el.color.cgColor
            // 文字是點陣 contents：重畫在下一個 display 週期，不在我們關掉動畫的 transaction 內，
            // 預設會淡入淡出 0.25 秒，舊點陣以新的 contentsScale 顯示就成了放大 / 縮小的殘影
            text.actions = ["contents": NSNull()]
            layer = text
        default:
            let shape = CAShapeLayer()
            shape.strokeColor = el.color.cgColor
            shape.lineWidth = 2
            shape.lineJoin = .round
            shape.lineCap = .round
            let local = CGRect(origin: .zero, size: b.size)
            switch el.kind {
            case .rectangle:
                shape.path = UIBezierPath(roundedRect: local, cornerRadius: 8).cgPath
                shape.fillColor = el.color.withAlphaComponent(0.12).cgColor
            case .ellipse:
                shape.path = UIBezierPath(ovalIn: local).cgPath
                shape.fillColor = el.color.withAlphaComponent(0.12).cgColor
            default:
                shape.path = Self.arrowPath(from: CGPoint(x: el.frame.minX - b.minX, y: el.frame.minY - b.minY),
                                            to: CGPoint(x: el.frame.maxX - b.minX, y: el.frame.maxY - b.minY))
                shape.fillColor = nil
            }
            layer = shape
        }
        layer.anchorPoint = .zero
        layer.frame = b
        layer.contentsScale = (window?.screen.scale ?? 2) * min(rasterScale, targetRaster)
        if el.id == selected { highlight(layer, true) }
        return layer
    }

    private static func arrowPath(from a: CGPoint, to b: CGPoint) -> CGPath {
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        for side in [CGFloat.pi * 0.85, -CGFloat.pi * 0.85] {
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x + 14 * cos(angle + side), y: b.y + 14 * sin(angle + side)))
        }
        return path.cgPath
    }

    private func highlight(_ layer: CALayer, _ on: Bool) {
        layer.borderColor = on ? UIColor.tintColor.cgColor : nil
        layer.borderWidth = on ? 2 : 0
    }

    // MARK: 對齊與裁切

    /// 螢幕座標 = 畫布座標 × zoom − contentOffset。在 scrollViewDidScroll / DidZoom 中同步設定，
    /// 與 PencilKit 的內容在同一個 CATransaction 提交，所以不會落後一幀。
    private func syncTransform() {
        let z = canvas.zoomScale, o = canvas.contentOffset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.setAffineTransform(CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: -o.x, ty: -o.y))
        contentLayer.position = .zero
        CATransaction.commit()
    }

    private var visibleCanvasRect: CGRect {
        let z = canvas.zoomScale, o = canvas.contentOffset
        let rect = CGRect(x: o.x / z, y: o.y / z, width: bounds.width / z, height: bounds.height / z)
        let buffer = max(rect.width, rect.height) * 0.25
        return rect.insetBy(dx: -buffer, dy: -buffer)
    }

    private func updateVisibleLayers() {
        let visible = culling ? visibleCanvasRect : .infinite
        // 從空的開始時元素依序出現，直接附加即可（避免 10,000 個元素時逐一找插入位置）
        let appendOnly = layers.isEmpty
        // 關閉裁切時一次建完（A/B 比較用），否則每幀最多建 layersPerFrame 個，剩下的交給 tick
        var budget = culling ? Self.layersPerFrame : .max
        needsMoreLayers = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 個人白板的量級（數千）直接線性掃描；正式版需要時再加格狀索引
        for el in elements {
            let inside = visible.intersects(el.bounds)
            if inside, layers[el.id] == nil {
                guard budget > 0 else { needsMoreLayers = true; continue }
                budget -= 1
                let layer = makeLayer(el)
                if appendOnly { contentLayer.addSublayer(layer) } else { insert(layer, for: el.id) }
                layers[el.id] = layer
            } else if !inside, let layer = layers.removeValue(forKey: el.id) {
                layer.removeFromSuperlayer()
            }
        }
        CATransaction.commit()
    }

    /// 依元素順序插入，維持疊放順序
    private func insert(_ layer: CALayer, for id: Int) {
        let next = layers.keys.filter { $0 > id }.min().flatMap { layers[$0] }
        if let next { contentLayer.insertSublayer(layer, below: next) } else { contentLayer.addSublayer(layer) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !hideStructure else { return }
        measure {
            syncTransform()
            updateVisibleLayers()
        }
    }

    /// 縮放中不重新點陣化既有的 layer（沿用舊點陣，可能暫時模糊）；新建的 layer 用目前的倍率
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !hideStructure else { return }
        measure {
            syncTransform()
            updateVisibleLayers()
        }
    }

    /// 縮放結束後分批重新點陣化畫面內的 layer
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard rescale, !hideStructure else { return }
        applyRaster(targetRaster)
    }

    private func measure(_ work: () -> Void) {
        let start = CACurrentMediaTime()
        work()
        worstCallback = max(worstCallback, CACurrentMediaTime() - start)
    }

    /// 點陣倍率 = 縮放倍率，限制在 0.25...4（關閉「重設 contentsScale」時固定 1）
    private var targetRaster: CGFloat {
        rescale ? min(max(canvas.zoomScale, 0.25), 4) : 1
    }

    private func applyRaster(_ scale: CGFloat) {
        rasterScale = scale
        let contentsScale = (window?.screen.scale ?? 2) * scale
        rasterQueue = layers.values.filter { $0.contentsScale != contentsScale }
    }

    /// 每幀重新點陣化一批；文字在同一個 transaction 內重畫，不留舊點陣
    private func drainRasterQueue() {
        guard !rasterQueue.isEmpty else { return }
        let contentsScale = (window?.screen.scale ?? 2) * rasterScale
        let batch = rasterQueue.suffix(Self.layersPerFrame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in batch where layer.superlayer != nil {
            layer.contentsScale = contentsScale
            layer.displayIfNeeded()
        }
        CATransaction.commit()
        rasterQueue.removeLast(batch.count)
    }

    // MARK: 手勢

    private func canvasPoint(_ gesture: UIGestureRecognizer) -> CGPoint {
        let p = gesture.location(in: canvas)
        return CGPoint(x: p.x / canvas.zoomScale, y: p.y / canvas.zoomScale)
    }

    private func hitTest(_ p: CGPoint) -> Int? {
        let tolerance = 10 / canvas.zoomScale
        for el in elements.reversed() where el.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) {
            switch el.kind {
            case .ellipse:
                if UIBezierPath(ovalIn: el.bounds.insetBy(dx: -tolerance, dy: -tolerance)).contains(p) { return el.id }
            case .arrow:
                if Self.distance(p, toSegment: el.frame.origin, CGPoint(x: el.frame.maxX, y: el.frame.maxY)) <= tolerance {
                    return el.id
                }
            default:
                return el.id
            }
        }
        return nil
    }

    private static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, .ulpOfOne)))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 只有碰到元素才開始；否則失敗，觸控交給 scroll view（捲動 / 縮放）或 PencilKit（書寫）
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === drag else { return super.gestureRecognizerShouldBegin(gesture) }
        return hitTest(canvasPoint(gesture)) != nil
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        select(hitTest(canvasPoint(gesture)))
    }

    @objc private func handleDrag(_ gesture: UILongPressGestureRecognizer) {
        let p = canvasPoint(gesture)
        switch gesture.state {
        case .began:
            guard let id = hitTest(p) else { return }
            select(id)
            let origin = elements[id].frame.origin
            dragOffset = CGSize(width: p.x - origin.x, height: p.y - origin.y)
        case .changed:
            guard let id = selected else { return }
            elements[id].frame.origin = CGPoint(x: p.x - dragOffset.width, y: p.y - dragOffset.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layers[id]?.frame = elements[id].bounds
            CATransaction.commit()
        default:
            break
        }
    }

    private func select(_ id: Int?) {
        if let old = selected, let layer = layers[old] { highlight(layer, false) }
        selected = id
        if let id, let layer = layers[id] { highlight(layer, true) }
        stats.selected = id
    }

    // MARK: 量測

    @objc private func tick(_ link: CADisplayLink) {
        if !hideStructure, needsMoreLayers || !rasterQueue.isEmpty {
            measure {
                if needsMoreLayers { updateVisibleLayers() }
                drainRasterQueue()
            }
        }
        if lastTimestamp > 0 { worstFrame = max(worstFrame, link.timestamp - lastTimestamp) }
        lastTimestamp = link.timestamp
        frameCount += 1
        if windowStart == 0 { windowStart = link.timestamp }
        if link.timestamp - windowStart >= 1 {
            stats.fps = frameCount
            stats.liveLayers = layers.count
            stats.zoom = canvas.zoomScale
            stats.rasterScale = rasterScale
            stats.worstCallbackMS = worstCallback * 1000
            stats.pendingWork = rasterQueue.count + (needsMoreLayers ? 1 : 0)
            worstCallback = 0
            stats.worstFrameMS = worstFrame * 1000
            frameCount = 0
            worstFrame = 0
            windowStart = link.timestamp
        }
    }
}

/// 固定種子，每次產生相同的元素分布，方便前後比較
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
#endif
