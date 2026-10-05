#if os(iOS)
import EasyNotesUI
import ExcalidrawKit
import PDFKit
import PencilKit
import UIKit

/// iPad / iPhone 的手寫（見 architecture/pdf.md「頁面疊層」「記憶體」「Undo 記在模型」）：
/// 每個可見頁的 overlay 有一個 `PKCanvasView`，畫完就把該頁筆畫換回 elements，所以 overlay 回收時直接丟掉畫布。
/// Undo 記在模型（頁碼 + 前後 elements），不靠會被回收的畫布。
extension PDFReaderCanvas {
    func setUpInking() {
        let tap = InkPencilInteraction { [weak self] in self?.inking == true }
        addInteraction(tap.interaction)
        pencilTap = tap
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged,
                                               object: pdfView)
    }

    /// 放進視窗的同一輪 SwiftUI 還在調整階層，延到下一輪才成為 first responder（⌘Z 才找得到）
    func inkingDidMoveToWindow() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            becomeFirstResponder()
        }
    }

    /// 工具列選了別的手寫工具：所有畫布一起換
    func setTool(_ spec: InkToolSpec) {
        guard spec != inkTool else { return }
        inkTool = spec
        for overlay in overlays.values { overlay.canvas.tool = spec.pkTool }
    }

    /// 手寫模式：Pencil 書寫（iPhone 手指也能寫）、手指捲動縮放
    func setInking(_ on: Bool) {
        guard on != inking else { return }
        inking = on
        // 版面依 isInMarkupMode 而不同：overlay 重新換算（`PageOverlayView.updateLayout`）
        pdfView.isInMarkupMode = on
        for overlay in overlays.values {
            configure(overlay)
            overlay.setNeedsLayout()
        }
        reclaimFirstResponder()
        applyStickyInking()
    }

    /// 便利貼文字框拿走 first responder 之後搶回來，⌘Z 才找得到這裡的模型 Undo
    func reclaimFirstResponder() {
        guard window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    private static var drawingPolicy: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(simulator)
        .anyInput // 模擬器沒有 Pencil
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .pencilOnly : .anyInput
        #endif
    }

    /// overlay 一律接收觸控（便利貼；非手寫模式由 `hitTest` 只攔便利貼），畫布只在手寫模式
    private func configure(_ overlay: PageOverlayView) {
        overlay.isUserInteractionEnabled = true
        overlay.canvas.isUserInteractionEnabled = inking
        overlay.canvas.drawingPolicy = Self.drawingPolicy
        overlay.canvas.drawingGestureRecognizer.isEnabled = inking
    }

    /// 新的 overlay：畫布用目前的手寫工具
    func attachCanvas(of overlay: PageOverlayView) {
        configure(overlay)
        overlay.canvas.tool = inkTool.pkTool
    }

    // MARK: 寫回模型

    /// 畫布的筆畫改變：換回頁面座標寫進模型，以「頁碼 + 前後 elements」註冊 Undo
    func canvasDrawingDidChange(_ overlay: PageOverlayView) {
        let strokes = PageInk.strokes(overlay.canvas.drawing, viewToPage: overlay.pageToView.inverted())
        undoableEdit(page: overlay.pageIndex, fromCanvas: true) { $0.replaceInk(with: strokes) }
        // PencilKit 在 delegate 之後才往畫布註冊自己的 undo（指向會被回收的畫布）：下一輪再丟掉
        let canvas = overlay.canvas
        DispatchQueue.main.async { canvas.privateUndo.removeAllActions() }
    }

    /// 修改一頁並註冊 Undo（只記有變的元素）。`fromCanvas`：筆畫就是畫布寫回來的，不必再載回畫布
    func undoableEdit(page: Int, fromCanvas: Bool = false, _ body: (inout ExcalidrawScene) -> Void) {
        let before = document.scene(page: page).elements
        if fromCanvas { syncingPage = page }
        document.edit(page: page, body)
        syncingPage = nil
        let (undo, redo) = PageInk.snapshots(from: before, to: document.scene(page: page).elements)
        if !undo.isEmpty { register(PageUndo(page: page, undo: undo, redo: redo)) }
    }

    /// 工具列的復原 / 重做：先結束便利貼的文字編輯（寫回後才是一個可復原的步驟）
    func undo() {
        endEditing()
        if modelUndo.canUndo { modelUndo.undo() }
    }

    func redo() {
        endEditing()
        if modelUndo.canRedo { modelUndo.redo() }
    }

    private func register(_ record: PageUndo) {
        modelUndo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.revert(record) }
        }
    }

    /// 復原 / 重做：改模型（`version` 繼續遞增），頁面在畫面上才由 `refresh` 載回畫布；再註冊反方向
    private func revert(_ record: PageUndo) {
        document.edit(page: record.page) { $0.restore(record.undo) }
        register(record.reversed)
    }

    // MARK: 清晰度

    /// 縮放停止 0.25 秒後依實際倍率重設畫布的點陣倍率
    @objc private func scaleChanged() {
        rasterTask?.cancel()
        rasterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            for overlay in overlays.values {
                applyRaster(to: overlay)
                overlay.refreshSelection() // 外框維持相同的螢幕大小
            }
        }
    }

    /// 畫布在 PDFView 的縮放 transform 裡，PencilKit 預設以螢幕倍率點陣化：改成「螢幕倍率 × overlay 在視窗上的倍率」，
    /// 不設上限（倍率包含開啟時的 fit 縮放，設上限時 4–5× 就糊）
    func applyRaster(to overlay: PageOverlayView) {
        guard let window else { return }
        let a = overlay.convert(CGPoint.zero, to: window), b = overlay.convert(CGPoint(x: 1, y: 0), to: window)
        overlay.canvas.setRaster(window.screen.scale * max(hypot(b.x - a.x, b.y - a.y), 1))
    }
}

/// 一頁的 Undo 紀錄（UndoManager 的 handler 要求 Sendable；只在主執行緒使用）
private final class PageUndo: @unchecked Sendable {
    let page: Int
    let undo: ExcalidrawScene.Snapshot
    let redo: ExcalidrawScene.Snapshot

    init(page: Int, undo: ExcalidrawScene.Snapshot, redo: ExcalidrawScene.Snapshot) {
        self.page = page
        self.undo = undo
        self.redo = redo
    }

    var reversed: PageUndo { PageUndo(page: page, undo: redo, redo: undo) }
}

/// 回傳私有的 undoManager，吞掉 PencilKit 自己的 undo 註冊（它指向會被回收的畫布）
final class PageCanvas: PKCanvasView {
    let privateUndo = UndoManager()

    override var undoManager: UndoManager? { privateUndo }

    /// PencilKit 的點陣倍率；`PKCanvasView` 內部有自己的子 view，一併設定
    func setRaster(_ scale: CGFloat) {
        guard abs(contentScaleFactor - scale) > 0.01 else { return }
        func apply(_ view: UIView) {
            view.contentScaleFactor = scale
            view.subviews.forEach(apply)
        }
        apply(self)
    }
}
#endif
