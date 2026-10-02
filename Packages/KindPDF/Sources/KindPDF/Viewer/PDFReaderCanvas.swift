import ExcalidrawKit
import PDFKit
import QuartzCore
#if os(iOS)
import UIKit
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif

/// PDF 檢視器的畫布（iOS / macOS 共用）：`PDFView` + 每個可見頁面一個 overlay（見 architecture/pdf.md「頁面疊層」）。
/// overlay 由 PDFView 依頁面的顯示大小（已旋轉）擺放，離開畫面就回收；標註只存在 `PDFInkDocument`。
@MainActor
final class PDFReaderCanvas: PlatformView {
    let pdfView = PDFView()
    let document: PDFInkDocument
    private(set) var overlays: [Int: PageOverlayView] = [:]
    private var loadedRevision = -1
    #if os(macOS)
    var editing: StickyEditing?
    #endif

    init(document: PDFInkDocument) {
        self.document = document
        super.init(frame: .zero)
        pdfView.frame = bounds
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        #if os(iOS)
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.backgroundColor = .secondarySystemBackground
        #else
        pdfView.autoresizingMask = [.width, .height]
        #endif
        // 必須在指定 document 之前設定，否則已顯示的頁面不會要 overlay
        pdfView.pageOverlayViewProvider = self
        addSubview(pdfView)
        document.onInkChange = { [weak self] pages in self?.refresh(pages) }
        #if os(macOS)
        // 切換檔案、改名、同步合併前：先把編輯中的便利貼文字寫回
        document.flushHandler = { [weak self] in self?.endEditing() }
        #endif
        reloadIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// PDF 檔被換掉（`pdfRevision` 改變）才重新載入
    func reloadIfNeeded() {
        guard document.pdfRevision != loadedRevision else { return }
        loadedRevision = document.pdfRevision
        overlays.removeAll()
        pdfView.document = PDFDocument(url: document.pdfURL)
    }

    /// 標註改變：只重畫有 overlay 的頁
    private func refresh(_ pages: Set<Int>?) {
        for (index, overlay) in overlays where pages?.contains(index) ?? true {
            overlay.show(document.scene(page: index))
        }
    }

    var currentPageIndex: Int? {
        guard let page = pdfView.currentPage else { return nil }
        return pdfView.document?.index(for: page)
    }
}

// PDFKit 的協定沒有標 @MainActor，但一律在主執行緒呼叫
extension PDFReaderCanvas: @preconcurrency PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> PlatformView? {
        guard let index = view.document?.index(for: page) else { return nil }
        if let existing = overlays[index] { return existing }
        let overlay = PageOverlayView(page: page, pageIndex: index)
        overlay.host = self
        overlay.show(document.scene(page: index))
        overlays[index] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: PlatformView, for page: PDFPage) {
        guard let overlay = overlayView as? PageOverlayView else { return }
        #if os(macOS)
        if editing?.overlay === overlay { endEditing() }
        #endif
        // 標註只存在文件模型，overlay 直接丟掉
        if overlays[overlay.pageIndex] === overlay { overlays[overlay.pageIndex] = nil }
    }
}

/// 單頁 overlay：底層是標註層（`PageInkLayer`）。PDFKit 決定它的大小與 transform（iOS 的旋轉頁是未旋轉的 bounds
/// 加上旋轉 transform），所以「頁面座標 → overlay 座標」一律以 PDFKit 的換算求出，不自己假設版面。
@MainActor
final class PageOverlayView: PlatformView {
    let pageIndex: Int
    let geometry: PDFPageGeometry
    let inkLayer = PageInkLayer()
    private weak var page: PDFPage?
    weak var host: PDFReaderCanvas?
    private(set) var scene = ExcalidrawScene()
    /// 暫時不畫在標註層的元素（拖曳中的便利貼、編輯中的文字）
    var hiddenElements: Set<String> = [] {
        didSet { if hiddenElements != oldValue { inkLayer.show(scene.without(hiddenElements)) } }
    }
    #if os(macOS)
    var drag: StickyDrag?
    #endif
    /// 頁面座標（未旋轉、y 向下）→ overlay 座標
    private(set) var pageToView = CGAffineTransform.identity

    init(page: PDFPage, pageIndex: Int) {
        self.page = page
        self.pageIndex = pageIndex
        geometry = PDFPageGeometry(page: page)
        super.init(frame: .zero)
        #if os(iOS)
        backgroundColor = .clear
        // 唯讀：觸控交給 PDFView 捲動縮放
        isUserInteractionEnabled = false
        layer.addSublayer(inkLayer)
        #else
        wantsLayer = true
        layer?.addSublayer(inkLayer)
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ scene: ExcalidrawScene) {
        self.scene = scene
        inkLayer.show(scene.without(hiddenElements))
    }

    /// overlay 座標 → 頁面座標
    func pagePoint(_ viewPoint: CGPoint) -> CGPoint {
        viewPoint.applying(pageToView.inverted())
    }

    private var pdfView: PDFView? {
        var view = superview
        while let v = view, !(v is PDFView) { view = v.superview }
        return view as? PDFView
    }

    /// 以 PDFKit 換算頁面上三個點（原點、右上、左下）到 overlay，得到仿射變換
    private func updateLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.frame = bounds
        CATransaction.commit()
        guard let page, let pdfView, bounds.width > 0, geometry.size.width > 0, geometry.size.height > 0 else { return }
        let crop = page.bounds(for: .cropBox)
        func map(_ p: CGPoint) -> CGPoint {
            convert(pdfView.convert(geometry.toPDFSpace(p, cropBox: crop), from: page), from: pdfView)
        }
        let w = geometry.size.width, h = geometry.size.height
        let o = map(.zero), x = map(CGPoint(x: w, y: 0)), y = map(CGPoint(x: 0, y: h))
        pageToView = CGAffineTransform(a: (x.x - o.x) / w, b: (x.y - o.y) / w, c: (y.x - o.x) / h, d: (y.y - o.y) / h,
                                       tx: o.x, ty: o.y)
        inkLayer.setPageTransform(pageToView)
    }

    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        inkLayer.contentsScale = window?.screen.scale ?? 2
        setNeedsLayout()
    }
    #else
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        inkLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// 只在便利貼上（或編輯中的文字框）接收滑鼠，其餘交給 PDFView（選取文字、捲動）
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit !== self { return hit }
        return sticky(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) { stickyMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { stickyMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { stickyMouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? { stickyMenu(event) }
    #endif
}
