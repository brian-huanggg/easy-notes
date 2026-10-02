import ExcalidrawKit
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension ExcalidrawScene {
    /// 去掉某些元素（只給畫面用，不寫回）
    func without(_ ids: Set<String>) -> ExcalidrawScene {
        guard !ids.isEmpty else { return self }
        var scene = self
        scene.raw["elements"] = elements.filter { !ids.contains($0["id"] as? String ?? "") }
        return scene
    }

    /// 只留某些元素（拖曳預覽）
    func only(_ ids: Set<String>) -> ExcalidrawScene {
        var scene = self
        scene.raw["elements"] = elements.filter { ids.contains($0["id"] as? String ?? "") }
        return scene
    }

    /// 便利貼（容器）與它的文字
    func stickyIDs(_ id: String) -> Set<String> {
        Set([id] + liveElements.filter { $0.containerId == id }.map(\.id))
    }

    /// 設定便利貼的文字：沒有文字元素就新增一個（字級 14），文字依容器重新排版
    mutating func setStickyText(_ id: String, to text: String) {
        if let existing = liveElements.first(where: { $0.containerId == id && $0.type == .text }) {
            setText(existing.id, to: text)
        } else if !text.isEmpty, let textID = addBoundText(text, to: id) {
            mutate(textID) { $0.raw["fontSize"] = PDFStickies.fontSize }
            setText(textID, to: text)
        }
    }
}

enum PDFStickies {
    /// 預設大小（頁面點）與字級，見 architecture/pdf.md「便利貼」
    static let size: Double = 160
    static let fontSize: Double = 14
    /// 縮放的最小邊長（頁面點）
    static let minSize: Double = 40
    /// 便利貼底色 `#ffec99`、文字 `#1e1e1e`（與白板的便條紙相同）
    static let fill = CGColor(srgbRed: 1, green: 0xec / 255, blue: 0x99 / 255, alpha: 1)
    static let ink = CGColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1)
}

/// 拖曳中的便利貼：移動或拖曳右下角縮放。標註層隱藏它，`preview` 同步畫出拖曳中的樣子，放開才寫入一次
struct StickyDrag {
    enum Mode { case move, resize }
    let id: String
    let mode: Mode
    /// overlay 座標
    let start: CGPoint
    /// 開始拖曳時的便利貼（縮放每一幀都從它計算）
    let original: Element
    var preview: StickyPreviewView?
}

/// 編輯中的便利貼文字
struct StickyEditing {
    let id: String
    weak var overlay: PageOverlayView?
    let textView: StickyTextView
}

// MARK: - overlay：點選、拖曳（兩個平台共用）

extension PageOverlayView {
    /// 最上層、包含這個點的便利貼（overlay 座標）；外框顯示中的便利貼，縮放點優先
    func sticky(at viewPoint: CGPoint) -> Element? {
        let p = pagePoint(viewPoint)
        if let shown = chrome?.stickyID, let el = scene.element(shown), !el.isDeleted,
           handleRect(for: el).contains(viewPoint) { return el }
        return scene.liveElements.reversed().first { $0.type == .rectangle && $0.rect.standardized.contains(p) }
    }

    /// overlay 1 點在視窗上的大小：外框與縮放點在任何縮放倍率下都維持相同的螢幕大小
    var onScreenScale: CGFloat {
        #if os(iOS)
        guard let window else { return 1 }
        let a = convert(CGPoint.zero, to: window), b = convert(CGPoint(x: 1, y: 0), to: window)
        return max(hypot(b.x - a.x, b.y - a.y), 0.01)
        #else
        max(convert(NSSize(width: 1, height: 0), to: nil).width, 0.01)
        #endif
    }

    /// 縮放點的觸控範圍：頁面座標的右下角（旋轉頁上依顯示位置）
    func handleRect(for el: Element) -> CGRect {
        let corner = CGPoint(x: el.rect.standardized.maxX, y: el.rect.standardized.maxY).applying(pageToView)
        #if os(iOS)
        let size = 32 / onScreenScale // 手指
        #else
        let size = 14 / onScreenScale
        #endif
        return CGRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size)
    }

    func hideChrome() {
        chrome?.removeFromSuperview()
        chrome = nil
    }

    /// 外框與縮放點（`rect` 為頁面座標，省略時用目前的便利貼）
    func showChrome(for el: Element, rect: CGRect? = nil) {
        let r = (rect ?? el.rect.standardized).applying(pageToView)
        let pad = 8 / onScreenScale
        let view = chrome ?? StickyChromeView()
        if chrome == nil { addSubview(view); chrome = view } // 最上層（手寫之上）
        view.stickyID = el.id
        view.lineWidth = 1.5 / onScreenScale
        view.handleSize = 10 / onScreenScale
        view.padding = pad
        view.frame = r.insetBy(dx: -pad, dy: -pad)
        view.redraw()
    }

    func startDrag(_ el: Element, at p: CGPoint) {
        drag = StickyDrag(id: el.id, mode: handleRect(for: el).contains(p) ? .resize : .move, start: p, original: el)
    }

    /// 拖曳中：標註層隱藏這張，同步繪製的預覽跟著手指 / 游標
    func continueDrag(to p: CGPoint) {
        guard var drag else { return }
        if drag.preview == nil {
            let preview = StickyPreviewView(frame: bounds)
            preview.pageToView = pageToView
            #if os(iOS)
            preview.contentScaleFactor = canvas.contentScaleFactor
            insertSubview(preview, belowSubview: canvas) // 手寫在便利貼之上
            #else
            addSubview(preview, positioned: .below, relativeTo: chrome)
            #endif
            hiddenElements.formUnion(scene.stickyIDs(drag.id))
            drag.preview = preview
        }
        let (scene, rect) = dragged(drag, to: p)
        drag.preview?.scene = scene.only(scene.stickyIDs(drag.id))
        if let el = scene.element(drag.id) { showChrome(for: el, rect: rect) }
        self.drag = drag
    }

    /// 放開：寫入一次（`cancel` = 不寫入，回到原處）
    func endDrag(at p: CGPoint, cancel: Bool = false) {
        guard let drag else { return }
        self.drag = nil
        guard let preview = drag.preview else { return }
        let (_, rect) = dragged(drag, to: p)
        let ids = scene.stickyIDs(drag.id)
        // 先寫入新位置（仍隱藏），再取消隱藏：只重畫新位置，便利貼不會先閃回原處
        if !cancel, rect != drag.original.rect.standardized {
            host?.editStickies(page: pageIndex) { scene in
                switch drag.mode {
                case .move: scene.move([drag.id], dx: rect.minX - drag.original.x, dy: rect.minY - drag.original.y)
                case .resize: scene.resize(drag.id, to: rect, from: drag.original)
                }
            }
        }
        hiddenElements.subtract(ids)
        // 標註層在背景重畫完之前先留著預覽，避免便利貼閃一下
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { preview.removeFromSuperview() }
        if let el = scene.element(drag.id) { showChrome(for: el) }
    }

    /// 拖到 `p` 時的場景（只在記憶體）與便利貼的新範圍（頁面座標）
    private func dragged(_ drag: StickyDrag, to p: CGPoint) -> (ExcalidrawScene, CGRect) {
        let a = pagePoint(drag.start), b = pagePoint(p)
        let r = drag.original.rect.standardized
        var scene = self.scene
        switch drag.mode {
        case .move:
            let moved = r.offsetBy(dx: b.x - a.x, dy: b.y - a.y)
            scene.move([drag.id], dx: moved.minX - (scene.element(drag.id)?.x ?? r.minX),
                       dy: moved.minY - (scene.element(drag.id)?.y ?? r.minY))
            return (scene, moved)
        case .resize:
            let rect = CGRect(x: r.minX, y: r.minY, width: max(r.width + b.x - a.x, PDFStickies.minSize),
                              height: max(r.height + b.y - a.y, PDFStickies.minSize))
            scene.resize(drag.id, to: rect, from: drag.original)
            return (scene, scene.element(drag.id)?.rect.standardized ?? rect)
        }
    }

    /// 畫面上看得到的範圍（overlay 座標）；新增便利貼放在它的中央
    var visibleArea: CGRect {
        #if os(iOS)
        guard let host else { return bounds }
        let shown = bounds.intersection(host.pdfView.convert(host.pdfView.bounds, to: self))
        return shown.isNull || shown.isEmpty ? bounds : shown
        #else
        visibleRect.isEmpty ? bounds : visibleRect
        #endif
    }
}

// MARK: - 畫布：新增、刪除、寫入

extension PDFReaderCanvas {
    /// 在目前頁可見範圍的中央新增一張便利貼並開始編輯
    func addSticky() {
        endEditing()
        guard let index = currentPageIndex, let overlay = overlays[index] else { return }
        let visible = overlay.visibleArea
        let size = overlay.geometry.size, half = PDFStickies.size / 2
        let c = overlay.pagePoint(CGPoint(x: visible.midX, y: visible.midY))
        let x = min(max(c.x - half, 0), max(size.width - PDFStickies.size, 0))
        let y = min(max(c.y - half, 0), max(size.height - PDFStickies.size, 0))
        let el = Element.stickyNote(x: x, y: y, size: PDFStickies.size)
        editStickies(page: index) { $0.insert(el) }
        beginEditing(el.id, on: overlay)
    }

    func deleteSticky(_ id: String, on overlay: PageOverlayView) {
        endEditing()
        editStickies(page: overlay.pageIndex) { $0.delete([id]) }
    }

    /// 便利貼的修改：iOS 記進模型 Undo（停止操作 500 ms 後存檔）；macOS 立即存檔
    func editStickies(page: Int, _ body: (inout ExcalidrawScene) -> Void) {
        #if os(iOS)
        undoableEdit(page: page, body)
        #else
        document.edit(page: page, body)
        document.commit()
        #endif
    }
}

// MARK: - 預覽與外框

/// 拖曳中的便利貼：同步繪製（分塊的標註層是非同步畫的，移動時會缺塊、露出底下的 PDF 文字）
final class StickyPreviewView: PlatformView {
    var pageToView = CGAffineTransform.identity
    var scene = ExcalidrawScene() { didSet { renderer = SceneRenderer(scene: scene); redraw() } }
    private var renderer: SceneRenderer?

    #if os(iOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        paint(ctx)
    }
    #else
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        paint(ctx)
    }
    #endif

    private func paint(_ ctx: CGContext) {
        guard let renderer else { return }
        ctx.concatenate(pageToView)
        renderer.draw(in: ctx, pixelScale: hypot(ctx.ctm.a, ctx.ctm.b))
    }
}

/// 選取（iOS）或滑過（macOS）的便利貼：外框 + 右下角縮放點
final class StickyChromeView: PlatformView {
    var stickyID: String?
    var lineWidth: CGFloat = 1.5
    var handleSize: CGFloat = 10
    /// frame 比便利貼大這麼多（縮放點突出在外）
    var padding: CGFloat = 8

    #if os(iOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        paint(ctx, accent: tintColor.cgColor)
    }
    #else
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        paint(ctx, accent: NSColor.controlAccentColor.cgColor)
    }
    #endif

    private func paint(_ ctx: CGContext, accent: CGColor) {
        let box = bounds.insetBy(dx: padding, dy: padding)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(box)
        let knob = CGRect(x: box.maxX - handleSize / 2, y: box.maxY - handleSize / 2, width: handleSize, height: handleSize)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: knob)
        ctx.strokeEllipse(in: knob)
    }
}

extension PlatformView {
    func redraw() {
        #if os(iOS)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
    }
}
