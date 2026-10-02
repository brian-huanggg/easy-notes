#if os(iOS)
import PDFKit
import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Spike S4（見 Roadmap Phase 5）：驗證「`PDFView` + 每頁 overlay `PKCanvasView`」的疊層架構。
/// 只在 DEBUG 或啟動參數 `-PDFSpike YES` 時註冊成側邊欄面板；不讀寫 Vault。
/// 驗證項目：縮放後筆畫清晰且與頁面對齊（含旋轉頁）、手勢分工、共用一個 `PKToolPicker`、
/// 模型 Undo（overlay 回收後仍可跨頁復原）、200 頁快速捲動的記憶體。
struct PDFOverlaySpikeView: View {
    @State private var stats = PDFSpikeStats()
    @State private var options = PDFSpikeOptions()
    @State private var handle = PDFSpikeHandle()
    @State private var importing = false

    var body: some View {
        PDFSpikeRepresentable(stats: stats, options: options, handle: handle)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .topLeading) { hud }
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn: $options.markup) { Label("畫筆", systemImage: "pencil.tip.crop.circle") }
                    Button { handle.view?.undo() } label: { Label("復原", systemImage: "arrow.uturn.backward") }
                        .keyboardShortcut("z", modifiers: .command)
                    Button { handle.view?.redo() } label: { Label("重做", systemImage: "arrow.uturn.forward") }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Menu {
                        Toggle("自動捲動（壓力測試）", isOn: $options.autoScroll)
                        Toggle("縮放後重設 contentScaleFactor", isOn: $options.rescale)
                        Picker("點陣上限", selection: $options.rasterCap) {
                            Text("螢幕 × 4").tag(4.0)
                            Text("螢幕 × 6").tag(6.0)
                            Text("螢幕 × 8").tag(8.0)
                            Text("不限").tag(0.0)
                        }
                        Toggle("模型 Undo（關閉 = PencilKit 原生）", isOn: $options.modelUndo)
                        Toggle("手指也能書寫（Simulator）", isOn: $options.fingerDrawing)
                        Divider()
                        Button("加入對齊參考筆畫（每頁）") { handle.view?.addReferenceStrokes() }
                        Button("每頁加 30 筆隨機筆畫") { handle.view?.addRandomStrokes() }
                        Button("清除所有筆畫", role: .destructive) { handle.view?.clearInk() }
                        Button("重設記憶體峰值") { stats.peakMemoryMB = 0 }
                        Divider()
                        Button("載入 200 頁範例") { options.source = .sample }
                        Button("開啟 PDF…") { importing = true }
                    } label: {
                        Label("選項", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                // 複製一份到暫存區再開：PDFDocument 是延遲讀取，不能依賴 security-scoped 存取一直有效
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-spike.pdf")
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try? FileManager.default.removeItem(at: copy)
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { options.source = .file(copy) }
            }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FPS \(stats.fps)　最長一幀 \(stats.worstFrameMS, format: .number.precision(.fractionLength(1))) ms")
            Text("記憶體 \(stats.memoryMB, format: .number.precision(.fractionLength(0))) MB　峰值 \(stats.peakMemoryMB, format: .number.precision(.fractionLength(0))) MB")
            Text("頁 \(stats.page) / \(stats.pageCount)　overlay \(stats.liveOverlays)（累計 \(stats.createdOverlays)）　有筆畫 \(stats.inkPages) 頁")
            Text("縮放 \(stats.scale, format: .number.precision(.fractionLength(2)))×　螢幕上 \(stats.onScreen, format: .number.precision(.fractionLength(2)))×　raster \(stats.raster, format: .number.precision(.fractionLength(1)))　重新載入 \(stats.reloads)")
            Text("overlay \(stats.overlaySize)　cropBox \(stats.cropBox)　旋轉 \(stats.rotation)°")
            Text("Undo \(stats.canUndo ? "✓" : "—") Redo \(stats.canRedo ? "✓" : "—")　最近復原：\(stats.lastUndoPage.map { "第 \($0) 頁" } ?? "—")　PencilKit 被吞 \(stats.swallowed)")
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding()
        .allowsHitTesting(false)
    }
}

@Observable @MainActor
final class PDFSpikeStats {
    var fps = 0
    var worstFrameMS = 0.0
    var memoryMB = 0.0
    var peakMemoryMB = 0.0
    var page = 0
    var pageCount = 0
    var liveOverlays = 0
    var createdOverlays = 0
    var inkPages = 0
    var scale = 1.0
    var raster = 1.0
    /// overlay 實際在螢幕上的倍率（overlay 1 pt 換算成視窗幾 pt）；raster 要 ≥ 它 × 螢幕倍率才清晰
    var onScreen = 1.0
    /// overlay 尺寸改變時把筆畫重新換算到畫布上的次數（縮放中一直增加 = overlay 的 bounds 跟著縮放變）
    var reloads = 0
    var overlaySize = "—"
    var cropBox = "—"
    var rotation = 0
    var canUndo = false
    var canRedo = false
    var lastUndoPage: Int?
    /// PencilKit 往畫布的私有 undoManager 註冊、被丟掉的次數（> 0 代表吞掉有效）
    var swallowed = 0
}

@Observable @MainActor
final class PDFSpikeOptions {
    enum Source: Equatable { case sample, file(URL) }
    var source = Source.sample
    var markup = true
    var autoScroll = false
    var rescale = true
    /// 點陣倍率上限（螢幕倍率的幾倍）；0 = 不限。第一輪實機 4× 上限在 4–5× 縮放時筆畫變糊
    var rasterCap = 0.0
    var modelUndo = true
    var fingerDrawing = false
}

@MainActor
final class PDFSpikeHandle {
    weak var view: PDFSpikeCanvas?
}

private struct PDFSpikeRepresentable: UIViewRepresentable {
    let stats: PDFSpikeStats
    let options: PDFSpikeOptions
    let handle: PDFSpikeHandle

    func makeUIView(context: Context) -> PDFSpikeCanvas {
        let view = PDFSpikeCanvas(stats: stats)
        handle.view = view
        return view
    }

    func updateUIView(_ view: PDFSpikeCanvas, context: Context) {
        view.apply(source: options.source, markup: options.markup, autoScroll: options.autoScroll,
                   rescale: options.rescale, rasterCap: options.rasterCap, modelUndo: options.modelUndo, fingerDrawing: options.fingerDrawing)
    }
}

// MARK: - 畫布

/// 標註模型：頁碼 → 該頁的筆畫。座標是 cropBox 的**未旋轉**頁面座標（原點左上、y 向下、單位 PDF point），
/// 與正式格式相同；正式版存 Excalidraw elements（5a），spike 直接存 `PKDrawing`。
/// overlay 只是模型的暫時檢視：建立時從模型換算，畫完立刻寫回模型，所以回收時不必另外存。
final class PDFSpikeCanvas: UIView, PKToolPickerObserver {
    private let stats: PDFSpikeStats
    private let pdfView = PDFView()
    private let toolPicker = PKToolPicker()
    private let modelUndo = UndoManager()

    private var pages: [Int: PKDrawing] = [:]
    private var overlays: [Int: PageOverlay] = [:]
    private var source: PDFSpikeOptions.Source?
    private var markup = false
    private var autoScroll = false
    private var scrollDirection: CGFloat = 1
    private var rescale = true
    private var rasterCap = 0.0
    private var modelUndoEnabled = true
    private var fingerDrawing = false
    private var rasterTask: Task<Void, Never>?

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0
    private var worstFrame: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    /// HUD 每秒才更新一次（S3 的教訓：每幀改 SwiftUI 狀態會干擾量測），callback 裡只累計
    private var reloads = 0

    init(stats: PDFSpikeStats) {
        self.stats = stats
        super.init(frame: .zero)
        pdfView.frame = bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = .secondarySystemBackground
        // 必須在指定 document 之前設定，否則已顯示的頁面不會要 overlay
        pdfView.pageOverlayViewProvider = self
        addSubview(pdfView)
        toolPicker.addObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
    }

    required init?(coder: NSCoder) { fatalError() }

    // 工具選擇器綁在這個 view（常駐 first responder），不綁在某一頁的畫布：
    // 畫布會隨捲動回收，綁在畫布上的話它一回收工具選擇器就消失。
    override var canBecomeFirstResponder: Bool { true }
    // 視窗層級的 undo：模型 Undo 註冊在這裡，系統的三指撥動 / ⌘Z 也會找到它
    override var undoManager: UndoManager? { modelUndo }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateToolPicker()
    }

    func apply(source: PDFSpikeOptions.Source, markup: Bool, autoScroll: Bool, rescale: Bool, rasterCap: Double, modelUndo: Bool,
               fingerDrawing: Bool) {
        self.autoScroll = autoScroll
        if source != self.source {
            self.source = source
            load(source)
        }
        if rescale != self.rescale || rasterCap != self.rasterCap {
            self.rescale = rescale
            self.rasterCap = rasterCap
            scheduleRaster(delay: 0)
        }
        if modelUndo != modelUndoEnabled {
            modelUndoEnabled = modelUndo
            self.modelUndo.removeAllActions()
            for overlay in overlays.values { overlay.canvas.swallowsUndo = modelUndo }
            refreshUndoStats()
        }
        if markup != self.markup || fingerDrawing != self.fingerDrawing {
            self.markup = markup
            self.fingerDrawing = fingerDrawing
            pdfView.isInMarkupMode = markup
            for overlay in overlays.values { configure(overlay.canvas) }
            updateToolPicker()
        }
    }

    private func updateToolPicker() {
        guard window != nil else { return }
        toolPicker.setVisible(markup, forFirstResponder: self)
        if markup { becomeFirstResponder() }
    }

    private func configure(_ canvas: OverlayCanvas) {
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        canvas.drawingGestureRecognizer.isEnabled = markup
        canvas.isUserInteractionEnabled = markup
        canvas.swallowsUndo = modelUndoEnabled
        canvas.tool = toolPicker.selectedTool
    }

    // MARK: 文件

    private func load(_ source: PDFSpikeOptions.Source) {
        overlays.removeAll()
        pages.removeAll()
        modelUndo.removeAllActions()
        let document: PDFDocument?
        switch source {
        case .sample: document = Self.makeSample(pageCount: 200)
        case .file(let url): document = PDFDocument(url: url)
        }
        pdfView.document = document
        stats.pageCount = document?.pageCount ?? 0
        stats.createdOverlays = 0
        refreshInkStats()
        refreshUndoStats()
        pageChanged()
    }

    /// 範例：每 10 頁有一頁橫向；載入後把部分頁面設 `rotation`（90 / 180 / 270），檢查換算。
    /// 每頁畫藍色的參考框（內縮 36 pt）與左上角的 L 記號，「加入對齊參考筆畫」畫的紅線應該完全疊在上面。
    static func makeSample(pageCount: Int) -> PDFDocument? {
        let portrait = CGRect(x: 0, y: 0, width: 595, height: 842)
        let landscape = CGRect(x: 0, y: 0, width: 842, height: 595)
        let renderer = UIGraphicsPDFRenderer(bounds: portrait)
        let data = renderer.pdfData { context in
            for index in 0..<pageCount {
                let box = index % 10 == 3 ? landscape : portrait
                context.beginPage(withBounds: box, pageInfo: [:])
                let cg = context.cgContext
                cg.setStrokeColor(UIColor.systemGray5.cgColor)
                cg.setLineWidth(0.5)
                for y in stride(from: CGFloat(0), to: box.height, by: 24) {
                    cg.move(to: CGPoint(x: 0, y: y))
                    cg.addLine(to: CGPoint(x: box.width, y: y))
                }
                cg.strokePath()
                cg.setStrokeColor(UIColor.systemBlue.cgColor)
                cg.setLineWidth(1)
                cg.stroke(box.insetBy(dx: 36, dy: 36))
                cg.setLineWidth(3)
                cg.move(to: CGPoint(x: 136, y: 36))
                cg.addLine(to: CGPoint(x: 36, y: 36))
                cg.addLine(to: CGPoint(x: 36, y: 136))
                cg.strokePath()
                let title = "第 \(index + 1) 頁\(rotationForSample(index).map { "（rotation \($0)°）" } ?? "")"
                title.draw(at: CGPoint(x: 52, y: 48), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
                let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray]
                for line in 0..<Int((box.height - 200) / 24) {
                    "第 \(index + 1) 頁　第 \(line + 1) 行　上課講義範例文字 Lorem ipsum dolor sit amet, consectetur."
                        .draw(at: CGPoint(x: 56, y: 150 + CGFloat(line) * 24), withAttributes: body)
                }
            }
        }
        guard let document = PDFDocument(data: data) else { return nil }
        for index in 0..<document.pageCount {
            if let rotation = rotationForSample(index) { document.page(at: index)?.rotation = rotation }
        }
        return document
    }

    private static func rotationForSample(_ index: Int) -> Int? {
        switch index % 10 {
        case 5: 90
        case 7: 180
        case 9: 270
        default: nil
        }
    }

    // MARK: 座標

    /// 未旋轉頁面座標（cropBox 左上為原點、y 向下）→ overlay 座標（已套用 `rotation`，縮放到 overlay 大小）
    func viewFromPage(_ page: PDFPage, size: CGSize) -> CGAffineTransform {
        let box = page.bounds(for: .cropBox)
        let w = box.width, h = box.height
        let rotate: CGAffineTransform
        let shown: CGSize
        switch ((page.rotation % 360) + 360) % 360 {
        case 90: rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0); shown = CGSize(width: h, height: w)
        case 180: rotate = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h); shown = box.size
        case 270: rotate = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w); shown = CGSize(width: h, height: w)
        default: rotate = .identity; shown = box.size
        }
        guard shown.width > 0, shown.height > 0 else { return rotate }
        return rotate.concatenating(CGAffineTransform(scaleX: size.width / shown.width, y: size.height / shown.height))
    }

    // MARK: overlay 生命週期

    fileprivate func overlayDidLayout(_ overlay: PageOverlay) {
        guard let page = overlay.page, overlay.bounds.width > 0 else { return }
        let transform = viewFromPage(page, size: overlay.bounds.size)
        guard !overlay.loaded || transform != overlay.viewFromPage else { return }
        if overlay.loaded { reloads += 1 }
        overlay.viewFromPage = transform
        overlay.loaded = true
        overlay.show(pages[overlay.pageIndex] ?? PKDrawing())
        applyRaster(to: overlay)
    }

    fileprivate func drawingDidChange(_ overlay: PageOverlay) {
        guard overlay.loaded, !overlay.applying else { return }
        let index = overlay.pageIndex
        let before = pages[index] ?? PKDrawing()
        let after = overlay.canvas.drawing.transformed(using: overlay.viewFromPage.inverted())
        pages[index] = after.strokes.isEmpty ? nil : after
        if modelUndoEnabled {
            modelUndo.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.setPage(index, to: before, inverse: after) }
            }
        }
        // PencilKit 可能在 delegate 之後才註冊自己的 undo，下一輪 run loop 再檢查並丟掉
        let canvas = overlay.canvas
        DispatchQueue.main.async { [weak self] in
            guard let self, canvas.swallowsUndo, canvas.privateUndo.canUndo || canvas.privateUndo.canRedo else { return }
            stats.swallowed += 1
            canvas.privateUndo.removeAllActions()
            refreshUndoStats()
        }
        refreshInkStats()
        refreshUndoStats()
    }

    /// 模型 Undo：改模型，頁面在畫面上才同步給畫布；註冊反向動作當作 Redo
    private func setPage(_ index: Int, to drawing: PKDrawing, inverse: PKDrawing) {
        modelUndo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setPage(index, to: inverse, inverse: drawing) }
        }
        pages[index] = drawing.strokes.isEmpty ? nil : drawing
        overlays[index]?.show(drawing)
        stats.lastUndoPage = index + 1
        refreshInkStats()
        refreshUndoStats()
    }

    func undo() {
        if modelUndo.canUndo { modelUndo.undo() }
        refreshUndoStats()
    }

    func redo() {
        if modelUndo.canRedo { modelUndo.redo() }
        refreshUndoStats()
    }

    // MARK: 測試資料

    func addReferenceStrokes() {
        editAllPages { box in
            let r = CGRect(origin: .zero, size: box.size).insetBy(dx: 36, dy: 36)
            return [
                Self.stroke([r.origin, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                             CGPoint(x: r.minX, y: r.maxY), r.origin], color: .systemRed, width: 1.5),
                Self.stroke([CGPoint(x: 136, y: 36), CGPoint(x: 36, y: 36), CGPoint(x: 36, y: 136)], color: .systemRed, width: 1.5),
            ]
        }
    }

    func addRandomStrokes() {
        var generator = SystemRandomNumberGenerator()
        editAllPages { box in
            (0..<30).map { _ in
                var point = CGPoint(x: .random(in: 40...(box.width - 40), using: &generator),
                                    y: .random(in: 40...(box.height - 40), using: &generator))
                let points = (0..<24).map { _ in
                    point.x += .random(in: -8...8, using: &generator)
                    point.y += .random(in: -8...8, using: &generator)
                    return point
                }
                return Self.stroke(points, color: .systemIndigo, width: 2)
            }
        }
    }

    func clearInk() {
        pages.removeAll()
        modelUndo.removeAllActions()
        for overlay in overlays.values { overlay.show(PKDrawing()) }
        refreshInkStats()
        refreshUndoStats()
    }

    /// 直接改模型（不進 Undo），再同步給畫面上的頁
    private func editAllPages(_ strokes: (CGRect) -> [PKStroke]) {
        guard let document = pdfView.document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var drawing = pages[index] ?? PKDrawing()
            drawing.strokes += strokes(page.bounds(for: .cropBox))
            pages[index] = drawing
        }
        modelUndo.removeAllActions()
        for (index, overlay) in overlays { overlay.show(pages[index] ?? PKDrawing()) }
        refreshInkStats()
        refreshUndoStats()
    }

    private static func stroke(_ points: [CGPoint], color: UIColor, width: CGFloat) -> PKStroke {
        let controlPoints = points.enumerated().map { offset, location in
            PKStrokePoint(location: location, timeOffset: TimeInterval(offset) * 0.01, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
    }

    // MARK: 清晰度

    /// 縮放停止 0.25 秒後，依 overlay 實際在螢幕上的倍率重設畫布的點陣倍率
    @objc private func scaleChanged() {
        scheduleRaster(delay: 0.25)
    }

    private func scheduleRaster(delay: TimeInterval) {
        rasterTask?.cancel()
        rasterTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            for overlay in overlays.values { applyRaster(to: overlay) }
        }
    }

    private func applyRaster(to overlay: PageOverlay) {
        let screenScale = window?.screen.scale ?? 2
        var raster = screenScale
        if rescale, let window {
            let onScreen = overlay.convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: window).width
            raster = screenScale * max(onScreen, 1)
            if rasterCap > 0 { raster = min(raster, screenScale * rasterCap) }
        }
        overlay.canvas.setRaster(raster)
    }

    // MARK: 統計

    private var currentPageIndex: Int? {
        guard let page = pdfView.currentPage else { return nil }
        return pdfView.document?.index(for: page)
    }

    @objc private func pageChanged() {
        stats.page = (currentPageIndex ?? -1) + 1
        refreshPageStats()
    }

    private func refreshPageStats() {
        guard let index = currentPageIndex, let page = pdfView.document?.page(at: index) else { return }
        let box = page.bounds(for: .cropBox)
        stats.cropBox = "\(Int(box.width))×\(Int(box.height))"
        stats.rotation = page.rotation
        if let overlay = overlays[index] {
            stats.overlaySize = "\(Int(overlay.bounds.width))×\(Int(overlay.bounds.height))"
        }
    }

    private func refreshInkStats() {
        stats.inkPages = pages.count
    }

    private func refreshUndoStats() {
        stats.canUndo = modelUndo.canUndo
        stats.canRedo = modelUndo.canRedo
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp > 0 { worstFrame = max(worstFrame, now - lastTimestamp) }
        lastTimestamp = now
        frames += 1
        if autoScroll { stepAutoScroll(dt: link.targetTimestamp - now) }
        if windowStart == 0 { windowStart = now }
        guard now - windowStart >= 1 else { return }
        stats.fps = Int((Double(frames) / (now - windowStart)).rounded())
        stats.worstFrameMS = worstFrame * 1000
        stats.memoryMB = Self.footprintMB()
        stats.peakMemoryMB = max(stats.peakMemoryMB, stats.memoryMB)
        stats.liveOverlays = overlays.count
        stats.scale = pdfView.scaleFactor
        stats.reloads = reloads
        if let window, let index = currentPageIndex, let overlay = overlays[index] {
            stats.onScreen = overlay.convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: window).width
            stats.raster = overlay.canvas.contentScaleFactor
        }
        refreshPageStats()
        frames = 0
        worstFrame = 0
        windowStart = now
    }

    /// 約每秒 6,000 pt（A4 直式約 7 頁），到底就反向
    private func stepAutoScroll(dt: CFTimeInterval) {
        guard let scroll = pdfView.firstSubview(of: UIScrollView.self) else { return }
        let maxY = max(scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom, 0)
        var y = scroll.contentOffset.y + scrollDirection * 6_000 * dt
        if y >= maxY { y = maxY; scrollDirection = -1 }
        if y <= -scroll.adjustedContentInset.top { y = -scroll.adjustedContentInset.top; scrollDirection = 1 }
        scroll.contentOffset.y = y
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

// PDFKit 的協定沒有標 @MainActor，但一律在主執行緒呼叫
extension PDFSpikeCanvas: @preconcurrency PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let index = view.document?.index(for: page) else { return nil }
        if let existing = overlays[index] { return existing }
        let overlay = PageOverlay(page: page, pageIndex: index, host: self)
        configure(overlay.canvas)
        toolPicker.addObserver(overlay.canvas)
        overlays[index] = overlay
        stats.createdOverlays += 1
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageOverlay else { return }
        // 模型在每次畫完就更新了，這裡只要丟掉畫布
        toolPicker.removeObserver(overlay.canvas)
        if overlays[overlay.pageIndex] === overlay { overlays[overlay.pageIndex] = nil }
    }
}

// MARK: - 單頁 overlay

final class PageOverlay: UIView, PKCanvasViewDelegate {
    weak var page: PDFPage?
    let pageIndex: Int
    let canvas = OverlayCanvas()
    private weak var host: PDFSpikeCanvas?
    var viewFromPage = CGAffineTransform.identity
    var loaded = false
    /// 程式設定 `drawing` 時也會觸發 drawingDidChange，這段期間不寫回模型
    private(set) var applying = false

    init(page: PDFPage, pageIndex: Int, host: PDFSpikeCanvas) {
        self.page = page
        self.pageIndex = pageIndex
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // 畫布本身是 scroll view；關掉它的捲動，手指的拖曳才會交給 PDFView
        canvas.isScrollEnabled = false
        canvas.delegate = self
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        host?.overlayDidLayout(self)
    }

    func show(_ drawing: PKDrawing) {
        applying = true
        canvas.drawing = drawing.transformed(using: viewFromPage)
        applying = false
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        host?.drawingDidChange(self)
    }
}

/// 回傳私有的 undoManager，吞掉 PencilKit 自己的 undo 註冊（它指向會被回收的畫布）
final class OverlayCanvas: PKCanvasView {
    let privateUndo = UndoManager()
    var swallowsUndo = true

    override var undoManager: UndoManager? { swallowsUndo ? privateUndo : super.undoManager }

    /// PencilKit 的點陣倍率；`PKCanvasView` 內部有自己的子 view，一併設定
    func setRaster(_ scale: CGFloat) {
        func apply(_ view: UIView) {
            view.contentScaleFactor = scale
            view.subviews.forEach(apply)
        }
        apply(self)
    }
}

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
#endif
