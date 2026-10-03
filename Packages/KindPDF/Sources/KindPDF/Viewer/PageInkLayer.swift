import ExcalidrawKit
import QuartzCore

/// 一頁標註的繪製層（iOS / macOS 共用，見 architecture/pdf.md「標註層」）：`CATiledLayer` 依縮放倍率
/// 分塊重畫，放大也清晰、只畫看得到的區塊。分塊在背景執行緒繪製，所以內容以鎖保護、換內容時整個替換。
final class PageInkLayer: CATiledLayer, @unchecked Sendable {
    private let lock = NSLock()
    private var renderer: SceneRenderer?
    /// 頁面座標（未旋轉、y 向下）→ layer 座標；由 overlay 依 PDFKit 的換算提供
    private var pageToLayer: CGAffineTransform?
    /// iPad 的筆畫由上層的 `PKCanvasView` 顯示，這一層只畫便利貼
    private let drawsFreedraw: Bool

    init(drawsFreedraw: Bool) {
        self.drawsFreedraw = drawsFreedraw
        super.init()
        tileSize = CGSize(width: 512, height: 512)
        // 縮小時用較低的解析度，放大最多 2^6 倍仍依倍率重畫
        levelsOfDetail = 4
        levelsOfDetailBias = 6
        isOpaque = false
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        drawsFreedraw = (layer as? PageInkLayer)?.drawsFreedraw ?? true
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 換掉繪製內容後整層重畫；淡入會讓標註閃一下，關掉
    override class func fadeDuration() -> CFTimeInterval { 0 }

    /// `dirty`：只重畫這個範圍（layer 座標、y 向下），其餘分塊保留（整層重畫時分塊會暫時清空）；
    /// nil = 整層，`.null` = 不重畫（內容沒變）
    func show(_ scene: ExcalidrawScene, dirty: CGRect? = nil) {
        let renderer = SceneRenderer(scene: scene)
        let empty = !renderer.elements.contains { drawsFreedraw || $0.type != .freedraw }
        lock.withLock { self.renderer = empty ? nil : renderer }
        guard let dirty else { setNeedsDisplay(); return }
        guard !dirty.isNull, !dirty.isEmpty else { return }
        setNeedsDisplay(dirty)
        // macOS 未翻轉的 layer 是 y 向上：鏡像的範圍也重畫（多畫一塊無妨，少畫會留下舊內容）
        setNeedsDisplay(CGRect(x: dirty.minX, y: bounds.height - dirty.maxY, width: dirty.width, height: dirty.height))
    }

    func setPageTransform(_ transform: CGAffineTransform) {
        let changed = lock.withLock {
            defer { pageToLayer = transform }
            return pageToLayer.map { !$0.isNearlyEqual(transform) } ?? true
        }
        if changed { setNeedsDisplay() }
    }

    override func draw(in ctx: CGContext) {
        let (renderer, transform) = lock.withLock { (self.renderer, self.pageToLayer) }
        let size = bounds.size
        guard let renderer, let transform, size.width > 0 else { return }
        // layer 座標 y 向下；macOS 未翻轉的 layer 給的是 y 向上的 context
        if ctx.ctm.d > 0 {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.concatenate(transform)
        let pixelScale = hypot(ctx.ctm.a, ctx.ctm.b)
        renderer.draw(in: ctx, visible: ctx.boundingBoxOfClipPath, pixelScale: pixelScale, drawsFreedraw: drawsFreedraw)
    }
}

extension CGAffineTransform {
    func isNearlyEqual(_ o: CGAffineTransform, tolerance: CGFloat = 1e-4) -> Bool {
        abs(a - o.a) < tolerance && abs(b - o.b) < tolerance && abs(c - o.c) < tolerance && abs(d - o.d) < tolerance
            && abs(tx - o.tx) < tolerance * 100 && abs(ty - o.ty) < tolerance * 100
    }
}
