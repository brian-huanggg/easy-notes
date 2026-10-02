#if os(iOS)
import ExcalidrawKit
import PDFKit
import PencilKit
import UIKit

/// iPad / iPhone 的手寫（見 architecture/pdf.md「頁面疊層」「記憶體」「Undo 記在模型」）：
/// 每個可見頁的 overlay 有一個 `PKCanvasView`，畫完就把該頁筆畫換回 elements，所以 overlay 回收時直接丟掉畫布。
/// Undo 記在模型（頁碼 + 前後 elements），不靠會被回收的畫布。
extension PDFReaderCanvas {
    func setUpInking() {
        // 「用手指繪圖」由 drawingPolicy 固定，不讓使用者在工具盤切換
        toolPicker.showsDrawingPolicyControls = false
        // 畫布固定淺色（見 PageOverlayView），工具盤的顏色也用淺色版本，選的顏色才與畫出來的一致
        toolPicker.colorUserInterfaceStyle = .light
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged,
                                               object: pdfView)
    }

    /// 放進視窗的同一輪 SwiftUI 還在調整階層，延到下一輪才成為 first responder（⌘Z 與工具盤才找得到）
    func inkingDidMoveToWindow() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            becomeFirstResponder()
            updateToolPicker()
        }
    }

    /// 手寫模式：Pencil 書寫（iPhone 手指也能寫）、手指捲動縮放，顯示工具盤
    func setInking(_ on: Bool) {
        guard on != inking else { return }
        inking = on
        // 版面依 isInMarkupMode 而不同：overlay 重新換算（`PageOverlayView.updateLayout`）
        pdfView.isInMarkupMode = on
        for overlay in overlays.values {
            configure(overlay)
            overlay.setNeedsLayout()
        }
        updateToolPicker()
    }

    private func updateToolPicker() {
        guard window != nil else { return }
        toolPicker.setVisible(inking, forFirstResponder: self)
        if inking { becomeFirstResponder() }
    }

    private static var drawingPolicy: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(simulator)
        .anyInput // 模擬器沒有 Pencil
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .pencilOnly : .anyInput
        #endif
    }

    private func configure(_ overlay: PageOverlayView) {
        overlay.isUserInteractionEnabled = inking
        overlay.canvas.drawingPolicy = Self.drawingPolicy
        overlay.canvas.drawingGestureRecognizer.isEnabled = inking
    }

    /// 新的 overlay：畫布跟著共用工具盤
    func attachCanvas(of overlay: PageOverlayView) {
        configure(overlay)
        overlay.canvas.tool = toolPicker.selectedTool
        toolPicker.addObserver(overlay.canvas)
    }

    // MARK: 寫回模型

    /// 畫布的筆畫改變：換回頁面座標寫進模型，以「頁碼 + 前後 elements」註冊 Undo
    func canvasDrawingDidChange(_ overlay: PageOverlayView) {
        let index = overlay.pageIndex
        let strokes = PageInk.strokes(overlay.canvas.drawing, viewToPage: overlay.pageToView.inverted())
        let before = document.scene(page: index).elements
        syncingPage = index
        document.edit(page: index) { $0.replaceInk(with: strokes) }
        syncingPage = nil
        let (undo, redo) = PageInk.snapshots(from: before, to: document.scene(page: index).elements)
        if !undo.isEmpty { register(PageUndo(page: index, undo: undo, redo: redo)) }
        // PencilKit 在 delegate 之後才往畫布註冊自己的 undo（指向會被回收的畫布）：下一輪再丟掉
        let canvas = overlay.canvas
        DispatchQueue.main.async { canvas.privateUndo.removeAllActions() }
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
            for overlay in overlays.values { applyRaster(to: overlay) }
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
