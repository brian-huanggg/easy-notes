import EasyNotesUI
import ExcalidrawKit
import PDFKit
import QuartzCore
#if os(iOS)
import PencilKit
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
    var editing: StickyEditing?
    #if os(iOS)
    /// 所有頁面畫布共用的手寫工具（工具列的 `InkSettings`；新 overlay 建立時套用）
    var inkTool = InkSettings.shared.spec
    /// Pencil 點兩下切換工具（取代 `PKToolPicker` 原本的行為）
    var pencilTap: InkPencilInteraction?
    /// 模型 Undo（頁碼 + 前後 elements）；系統 ⌘Z、三指撥動經 responder chain 找到它
    let modelUndo = UndoManager()
    var inking = false
    var rasterTask: Task<Void, Never>?
    /// 正在把這一頁畫布的筆畫寫回模型：不必再把筆畫載回畫布
    var syncingPage: Int?
    /// 拖曳中的便利貼所在的頁
    weak var dragOverlay: PageOverlayView?
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
        // 切換檔案、改名、同步合併前：先把編輯中的便利貼文字寫回
        document.flushHandler = { [weak self] in self?.endEditing() }
        #if os(iOS)
        setUpInking()
        setUpStickies()
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
            #if os(iOS)
            overlay.show(document.scene(page: index), updatesCanvas: index != syncingPage)
            #else
            overlay.show(document.scene(page: index))
            #endif
        }
    }

    var currentPageIndex: Int? {
        guard let page = pdfView.currentPage else { return nil }
        return pdfView.document?.index(for: page)
    }

    #if os(iOS)
    // 工具盤綁在這個 view：它是常駐的 first responder（見 PDFInking.swift）
    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { modelUndo }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        inkingDidMoveToWindow()
    }
    #endif
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
        #if os(iOS)
        attachCanvas(of: overlay)
        #endif
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: PlatformView, for page: PDFPage) {
        guard let overlay = overlayView as? PageOverlayView else { return }
        if editing?.overlay === overlay { endEditing() }
        // 標註只存在文件模型，overlay 直接丟掉
        if overlays[overlay.pageIndex] === overlay { overlays[overlay.pageIndex] = nil }
    }
}

/// 單頁 overlay：底層是標註層（`PageInkLayer`），iOS 在上面疊 `PKCanvasView` 顯示與書寫筆畫。PDFKit 決定它的大小與 transform（iOS 的旋轉頁是未旋轉的 bounds
/// 加上旋轉 transform），所以「頁面座標 → overlay 座標」一律以 PDFKit 的換算求出，不自己假設版面。
@MainActor
final class PageOverlayView: PlatformView {
    let pageIndex: Int
    let geometry: PDFPageGeometry
    #if os(iOS)
    let inkLayer = PageInkLayer(drawsFreedraw: false)
    let canvas = PageCanvas()
    /// 畫筆停住變直線（見 architecture/ui.md「手寫工具列」）
    private(set) lazy var lineAssist = StraightLineAssist(canvas: canvas)
    /// 程式設定 `canvas.drawing` 也會觸發 `canvasViewDrawingDidChange`，這段期間不寫回模型
    private(set) var loadingDrawing = false
    #else
    let inkLayer = PageInkLayer(drawsFreedraw: true)
    #endif
    /// 已由 PDFKit 換算出 `pageToView`（之前畫布不載入筆畫）
    private var laidOut = false
    private weak var page: PDFPage?
    weak var host: PDFReaderCanvas?
    private(set) var scene = ExcalidrawScene()
    /// 標註層畫的部分：iOS 的筆畫由畫布顯示，不進標註層，所以筆畫改變時標註層不重畫
    /// （分塊在背景重畫完之前是空的，會露出便利貼底下的 PDF 文字）
    private var layerScene = ExcalidrawScene()
    /// 暫時不畫在標註層的元素（拖曳中的便利貼）
    var hiddenElements: Set<String> = [] {
        didSet {
            guard hiddenElements != oldValue else { return }
            // 只重畫這些元素的範圍：整層重畫時分塊會暫時清空
            let changed = hiddenElements.symmetricDifference(oldValue)
            let area = layerScene.liveElements.filter { changed.contains($0.id) }.map(Self.paintedBounds)
                .reduce(CGRect.null) { $0.union($1) }
            inkLayer.show(layerScene.without(hiddenElements), dirty: area.isNull ? .null : area.applying(pageToView))
        }
    }
    var drag: StickyDrag?
    /// 選取（iOS）或滑過（macOS）的便利貼的外框與縮放點
    var chrome: StickyChromeView?
    #if os(iOS)
    /// iOS 選取的便利貼（點一下選取，再點一下編輯）
    var selectedSticky: String?
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
        // 筆畫顏色是固定的 sRGB，PencilKit 在深色模式會反轉，頁面是白紙所以固定淺色
        overrideUserInterfaceStyle = .light
        // 非手寫模式：觸控交給 PDFView 捲動縮放
        isUserInteractionEnabled = false
        layer.addSublayer(inkLayer)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // 畫布本身是 scroll view；關掉它的捲動，手指的拖曳才會交給 PDFView
        canvas.isScrollEnabled = false
        canvas.delegate = self
        addSubview(canvas)
        _ = lineAssist
        addInteraction(UIEditMenuInteraction(delegate: self))
        #else
        wantsLayer = true
        layer?.addSublayer(inkLayer)
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `updatesCanvas`：iOS 是否把筆畫載入畫布（筆畫就是從畫布寫回來的時候不必）
    func show(_ scene: ExcalidrawScene, updatesCanvas: Bool = true) {
        let old = layerScene
        self.scene = scene
        layerScene = Self.forLayer(scene)
        let area = Self.changedArea(from: old, to: layerScene)
        inkLayer.show(layerScene.without(hiddenElements), dirty: area.isNull ? .null : area.applying(pageToView))
        #if os(iOS)
        if updatesCanvas, laidOut { loadDrawing() }
        refreshSelection()
        #endif
    }

    #if os(iOS)
    /// 模型的筆畫（頁面座標）換算到畫布
    private func loadDrawing() {
        loadingDrawing = true
        canvas.drawing = PageInk.drawing(scene, pageToView: pageToView)
        loadingDrawing = false
    }
    #endif

    private static func forLayer(_ scene: ExcalidrawScene) -> ExcalidrawScene {
        #if os(iOS)
        var layer = scene
        layer.raw["elements"] = scene.elements.filter { $0["type"] as? String != "freedraw" }
        return layer
        #else
        scene
        #endif
    }

    /// 改變的元素（新增、刪除、`version` 不同）前後範圍的聯集（頁面座標）；沒有改變為 `.null`
    static func changedArea(from old: ExcalidrawScene, to new: ExcalidrawScene) -> CGRect {
        var before = Dictionary(old.orderedElements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var area = CGRect.null
        for el in new.orderedElements {
            let prev = before.removeValue(forKey: el.id)
            if let prev, prev.version == el.version, prev.versionNonce == el.versionNonce, prev.isDeleted == el.isDeleted { continue }
            if let prev, !prev.isDeleted { area = area.union(paintedBounds(prev)) }
            if !el.isDeleted { area = area.union(paintedBounds(el)) }
        }
        for prev in before.values where !prev.isDeleted { area = area.union(paintedBounds(prev)) }
        return area
    }

    /// 元素的範圍加上筆畫寬度的餘裕
    static func paintedBounds(_ el: Element) -> CGRect {
        ElementGeometry.bounds(el).insetBy(dx: -16, dy: -16)
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
        #if os(iOS)
        canvas.frame = bounds
        #endif
        guard let page, let pdfView, bounds.width > 0, geometry.size.width > 0, geometry.size.height > 0 else { return }
        let crop = page.bounds(for: .cropBox)
        func map(_ p: CGPoint) -> CGPoint {
            convert(pdfView.convert(geometry.toPDFSpace(p, cropBox: crop), from: page), from: pdfView)
        }
        let w = geometry.size.width, h = geometry.size.height
        let o = map(.zero), x = map(CGPoint(x: w, y: 0)), y = map(CGPoint(x: 0, y: h))
        let next = CGAffineTransform(a: (x.x - o.x) / w, b: (x.y - o.y) / w, c: (y.x - o.x) / h, d: (y.y - o.y) / h,
                                     tx: o.x, ty: o.y)
        let changed = !laidOut || !next.isNearlyEqual(pageToView)
        pageToView = next
        laidOut = true
        inkLayer.setPageTransform(pageToView)
        #if os(iOS)
        // overlay 的版面改變（例如切換手寫模式）：筆畫重新換算到畫布
        if changed { loadDrawing() }
        host?.applyRaster(to: self)
        refreshSelection()
        #endif
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

    /// overlay 自己不攔觸控：便利貼的手勢裝在 `PDFReaderCanvas`（PDFKit 不一定把觸控交給 overlay）。
    /// 只有手寫模式的畫布與編輯中的文字框接收觸控，其餘交給 PDFView（捲動、選取文字）
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event), hit !== self else { return nil }
        if let textView = host?.editing?.textView, hit.isDescendant(of: textView) { return hit }
        return host?.inking == true && hit.isDescendant(of: canvas) ? hit : nil
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // 調整直線中的變動（取消 PencilKit 的筆畫）不寫回；放開加進直線時才寫回，模型 Undo 是一筆
        guard !loadingDrawing, laidOut, !lineAssist.isAdjusting else { return }
        host?.canvasDrawingDidChange(self)
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { stickyMouseMoved(event) }
    override func mouseExited(with event: NSEvent) { if drag == nil { hideChrome() } }
    override func mouseDown(with event: NSEvent) { stickyMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { stickyMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { stickyMouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? { stickyMenu(event) }
    #endif
}

#if os(iOS)
extension PageOverlayView: PKCanvasViewDelegate {}
#endif
