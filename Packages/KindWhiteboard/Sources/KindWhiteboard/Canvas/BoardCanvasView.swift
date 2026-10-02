#if os(iOS)
import PencilKit
import UIKit

/// iPad / iPhone 的白板畫布（見 Architecture「Whiteboard」）。
/// 下層：`structureHost` 裡的 `BoardLayerTree`，以 transform 跟著 `PKCanvasView` 的 contentOffset / zoomScale。
/// 上層：透明的 `PKCanvasView`，負責手寫、捲動、縮放與所有觸控。
///
/// 座標：場景座標（檔案）−`region.origin` = 內容座標（`PKCanvasView` 與筆畫）。筆畫只在載入與存檔時換算。
final class BoardCanvasView: UIView, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    let tree = BoardLayerTree(drawsFreedraw: false)
    let toolPicker = PKToolPicker()

    private let document: BoardDocument
    private let structureHost = UIView()
    private var region: CanvasRegion
    private var saveTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var didPlaceInitialView = false

    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 4

    init(document: BoardDocument) {
        self.document = document
        region = CanvasRegion(covering: ElementGeometry.bounds(of: document.scene.liveElements))
        super.init(frame: .zero)

        // 結構元素的顏色是固定的（#1e1e1e 等），PencilKit 在深色模式會反轉筆畫顏色，所以畫布固定淺色
        overrideUserInterfaceStyle = .light
        backgroundColor = Self.background(of: document.scene)

        structureHost.isUserInteractionEnabled = false
        structureHost.layer.addSublayer(tree.root)
        addSubview(structureHost)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.minimumZoomScale = Self.minZoom
        canvas.maximumZoomScale = Self.maxZoom
        // 回彈是 Core Animation 動畫，期間沒有逐幀回呼，結構層會與筆畫對不上
        canvas.bouncesZoom = false
        // 手勢分工：iPad 上 Pencil 書寫、手指捲動與縮放（不跟隨系統「僅使用 Apple Pencil 繪圖」設定，
        // 否則沒開那個設定時單指會畫出筆畫）。iPhone 通常沒有 Pencil，手指也能畫；模擬器沒有 Pencil
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .pencilOnly : .anyInput
        #endif
        canvas.contentSize = region.size
        canvas.drawing = contentDrawing()
        addSubview(canvas)

        toolPicker.addObserver(canvas)
        tree.setScene(document.scene)

        // 外部寫入併進場景後：更新結構層、把新筆畫畫上去。存檔時筆畫與場景比對，沒變的元素不會被改動
        document.onExternalChange = { [weak self] in
            guard let self else { return }
            if let all = ElementGeometry.bounds(of: document.scene.liveElements),
               let next = region.expanded(toInclude: all) { apply(next) }
            canvas.drawing = contentDrawing()
            tree.setScene(document.scene)
            scheduleWork()
        }
        document.flushHandler = { [weak self] in self?.saveNow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        structureHost.frame = bounds
        canvas.frame = bounds
        if !didPlaceInitialView, bounds.width > 0 {
            didPlaceInitialView = true
            placeInitialView()
        }
        syncTransform()
        updateVisible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            tree.setContentsScale(screenScale * rasterScale)
            scheduleWork()
            toolPicker.setVisible(true, forFirstResponder: canvas)
            // 放進視窗的同一輪 SwiftUI 還在調整階層，延到下一輪才成為 first responder（工具盤才會出現）
            DispatchQueue.main.async { [weak self] in self?.canvas.becomeFirstResponder() }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// 開啟時：縮放 1×，內容左上角（留一點邊）對齊畫面左上；空白板顯示場景原點
    private func placeInitialView() {
        let content = ElementGeometry.bounds(of: document.scene.liveElements)
        let target = content.map { CGPoint(x: $0.minX - 40, y: $0.minY - 40) } ?? CGPoint(x: -40, y: -40)
        canvas.contentOffset = region.toContent(target)
    }

    // MARK: 存檔

    /// 存檔時把筆畫換回場景座標
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let drawing = canvas.drawing.transformed(using: CGAffineTransform(translationX: region.origin.x, y: region.origin.y))
        document.commit { $0.update(from: drawing) }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func contentDrawing() -> PKDrawing {
        document.scene.drawing.transformed(using: CGAffineTransform(translationX: -region.origin.x, y: -region.origin.y))
    }

    // MARK: 對齊與裁切

    /// 螢幕座標 = (場景座標 − origin) × zoom − contentOffset。在 scrollViewDidScroll / DidZoom 中同步設定，
    /// 與 PencilKit 的內容在同一個 CATransaction 提交，不會落後一幀
    private func syncTransform() {
        let z = canvas.zoomScale, o = canvas.contentOffset, origin = region.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tree.root.setAffineTransform(CGAffineTransform(a: z, b: 0, c: 0, d: z,
                                                       tx: -origin.x * z - o.x, ty: -origin.y * z - o.y))
        tree.root.position = .zero
        CATransaction.commit()
    }

    /// 畫面看到的範圍（場景座標）
    var visibleSceneRect: CGRect {
        let z = canvas.zoomScale, o = canvas.contentOffset
        return CGRect(x: o.x / z + region.origin.x, y: o.y / z + region.origin.y,
                      width: bounds.width / z, height: bounds.height / z)
    }

    /// 只為畫面內（外加四分之一畫面的緩衝）的元素建立 layer
    private func updateVisible() {
        let rect = visibleSceneRect
        let buffer = max(rect.width, rect.height) * 0.25
        if tree.updateVisible(rect.insetBy(dx: -buffer, dy: -buffer)) { scheduleWork() }
    }

    // MARK: 無限畫布

    /// 停止捲動後檢查是否接近邊緣（捲動中改 contentOffset 會干擾慣性）
    private func growIfNeeded() {
        guard let next = region.expanded(toShow: visibleSceneRect) else { return }
        apply(next)
    }

    /// 換成新的範圍：往左 / 上擴大時筆畫與 contentOffset 平移同樣的量，畫面不動
    private func apply(_ next: CanvasRegion) {
        let shift = CGPoint(x: region.origin.x - next.origin.x, y: region.origin.y - next.origin.y)
        let z = canvas.zoomScale
        let offset = canvas.contentOffset
        saveNow() // 先存目前的筆畫（用舊的 origin 換算）
        region = next
        // PKCanvasView 的 contentSize 是縮放後的大小（與 Apple 的 PencilKitDraw 範例相同）
        canvas.contentSize = CGSize(width: next.size.width * z, height: next.size.height * z)
        if shift != .zero {
            canvas.drawing = canvas.drawing.transformed(using: CGAffineTransform(translationX: shift.x, y: shift.y))
            canvas.contentOffset = CGPoint(x: offset.x + shift.x * z, y: offset.y + shift.y * z)
        }
        syncTransform()
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncTransform()
        updateVisible()
    }

    /// 縮放中不重新點陣化既有的 layer（沿用舊點陣，暫時模糊）；新建的 layer 用 min(目前倍率, 縮放倍率)
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncTransform()
        tree.setContentsScale(screenScale * rasterScale, immediate: false)
        updateVisible()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        tree.setContentsScale(screenScale * rasterScale)
        scheduleWork()
        growIfNeeded()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { growIfNeeded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        growIfNeeded()
    }

    // MARK: 分批工作

    private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    /// 點陣倍率 = 縮放倍率（0.25…4）
    private var rasterScale: CGFloat { min(max(canvas.zoomScale, Self.minZoom), Self.maxZoom) }

    /// 有分批工作才開 display link，做完就關（閒置時不跑任何計時器）
    private func scheduleWork() {
        guard displayLink == nil, window != nil, tree.hasPendingWork else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick() {
        updateVisible()
        tree.drainRaster()
        if !tree.hasPendingWork {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    // MARK: 背景

    static func background(of scene: ExcalidrawScene) -> UIColor {
        let hex = (scene.raw["appState"] as? [String: Any])?["viewBackgroundColor"] as? String
        return SceneColor.parse(hex ?? "#ffffff").map(UIColor.init(cgColor:)) ?? .white
    }
}

/// CADisplayLink 會強引用 target；經由弱引用的 proxy，畫布關閉時不會被留住
private final class DisplayLinkProxy: NSObject {
    weak var view: BoardCanvasView?

    init(_ view: BoardCanvasView) { self.view = view }

    @MainActor @objc func tick() { view?.tick() }
}
#endif
