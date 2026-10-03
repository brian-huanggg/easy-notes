import CoreGraphics
import ExcalidrawKit
import Foundation
import QuartzCore

/// 縮得很小又有很多元素時，以一張點陣快照取代個別 layer（見 architecture/whiteboard.md「4c：macOS 宿主、快捷鍵、LOD」）。
/// iOS / macOS 共用：宿主把 `root` 放在結構層旁、套同樣的 transform，並在每次捲動 / 縮放後呼叫 `viewChanged`。
///
/// - 條件：縮放倍率 ≤ `zoomThreshold`、可見範圍內的元素 > `elementThreshold`、沒有選取或操作中。
/// - 第一張快照在背景畫好之前仍顯示個別 layer；之後結構層不建立 layer（`tree.lodActive`），
///   縮放 / 平移時圖片跟著 transform，停止 `debounce` 後依新範圍與倍率重畫。
@MainActor
final class BoardLOD {
    static let zoomThreshold: CGFloat = 0.4
    static let elementThreshold = 1_500
    static let debounce: Duration = .milliseconds(150)
    /// 快照涵蓋可見範圍外擴的比例（每邊）
    static let margin: CGFloat = 0.25
    /// 快照最長邊的像素上限（記憶體：4096 × 3072 × 4 ≈ 48 MB）
    static let maxPixels: CGFloat = 4096
    /// 快照倍率與目前縮放相差超過這個比例就重畫
    static let scaleTolerance: CGFloat = 1.5

    let root: LODLayer = LODLayer()
    private(set) var isActive = false

    private let tree: BoardLayerTree
    private let scene: @MainActor () -> ExcalidrawScene
    private let drawsFreedraw: Bool
    private var snapshot: (rect: CGRect, zoom: CGFloat)?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// 最近一次 `viewChanged` 的參數（場景改變時重畫用）
    private var last: (visible: CGRect, zoom: CGFloat, screenScale: CGFloat, idle: Bool)?

    init(tree: BoardLayerTree, drawsFreedraw: Bool, scene: @escaping @MainActor () -> ExcalidrawScene) {
        self.tree = tree
        self.drawsFreedraw = drawsFreedraw
        self.scene = scene
        root.isHidden = true
    }

    /// 是否該用 LOD（純函式，給測試）
    static func shouldUse(count: Int, zoom: CGFloat, idle: Bool) -> Bool {
        idle && zoom <= zoomThreshold && count > elementThreshold
    }

    /// 畫面範圍或縮放改變。`idle` = 沒有選取、沒有進行中的操作與文字編輯
    func viewChanged(visible: CGRect, zoom: CGFloat, screenScale: CGFloat, idle: Bool) {
        last = (visible, zoom, screenScale, idle)
        guard Self.shouldUse(count: tree.visibleCount(in: visible), zoom: zoom, idle: idle) else {
            deactivate()
            return
        }
        if let snapshot, snapshot.rect.contains(visible), isSharp(snapshot.zoom, zoom) { return }
        // 還沒有快照：馬上畫（個別 layer 先頂著）；已啟用：等停止操作再重畫，期間圖片跟著 transform
        schedule(after: isActive ? Self.debounce : .zero)
    }

    /// 場景內容變了（外部變動、結構操作）：作廢目前的快照。宿主接著呼叫 `viewChanged`（帶最新的 `idle`）重畫
    func sceneChanged() {
        snapshot = nil
    }

    private func isSharp(_ snapshotZoom: CGFloat, _ zoom: CGFloat) -> Bool {
        let ratio = zoom / snapshotZoom
        return ratio <= Self.scaleTolerance && ratio >= 1 / Self.scaleTolerance
    }

    func deactivate() {
        generation += 1
        task?.cancel()
        task = nil
        snapshot = nil
        guard isActive else { return }
        isActive = false
        root.isHidden = true
        root.image = nil
        tree.lodActive = false
    }

    private func schedule(after delay: Duration) {
        generation += 1
        let mine = generation
        task?.cancel()
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.renderSnapshot(generation: mine)
        }
    }

    private func renderSnapshot(generation mine: Int) async {
        guard mine == generation, let last else { return }
        let rect = Self.snapshotRect(for: last.visible)
        let scale = Self.pixelScale(rect: rect, zoom: last.zoom, screenScale: last.screenScale)
        let renderer = SceneRenderer(scene: scene())
        let freedraw = drawsFreedraw
        let image = await Task.detached(priority: .userInitiated) {
            Self.render(renderer, rect: rect, scale: scale, drawsFreedraw: freedraw)
        }.value
        guard mine == generation, let image else { return }
        snapshot = (rect, last.zoom)
        root.show(image, rect: rect, scale: scale)
        root.isHidden = false
        isActive = true
        tree.lodActive = true
    }

    // MARK: 計算

    static func snapshotRect(for visible: CGRect) -> CGRect {
        visible.insetBy(dx: -visible.width * margin, dy: -visible.height * margin)
    }

    /// 每個畫布單位的像素數：螢幕上看到的解析度，但最長邊不超過 `maxPixels`
    static func pixelScale(rect: CGRect, zoom: CGFloat, screenScale: CGFloat) -> CGFloat {
        min(zoom * screenScale, maxPixels / max(rect.width, rect.height, 1))
    }

    /// 把 `rect` 範圍內的元素畫成圖片（透明背景，畫布座標 y 向下）。背景執行緒可用
    nonisolated static func render(_ renderer: SceneRenderer, rect: CGRect, scale: CGFloat,
                                   drawsFreedraw: Bool) -> CGImage? {
        let width = max(1, Int((rect.width * scale).rounded(.up))), height = max(1, Int((rect.height * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        renderer.draw(in: ctx, visible: rect, pixelScale: scale, drawsFreedraw: drawsFreedraw)
        return ctx.makeImage()
    }
}

/// 顯示快照的 layer：bounds = 快照範圍的大小、position = 範圍左上角（畫布座標），跟著結構層的 transform
final class LODLayer: PlainLayer {
    var image: CGImage? {
        didSet { setNeedsDisplay() }
    }

    func show(_ image: CGImage, rect: CGRect, scale: CGFloat) {
        anchorPoint = .zero
        bounds = CGRect(origin: .zero, size: rect.size)
        position = rect.origin
        contentsScale = scale
        self.image = image
    }

    override func draw(in ctx: CGContext) {
        guard let image else { return }
        // 與 PaintedLayer 相同：先換成 y 向下的座標，再把（y 向上的）圖片翻正
        #if os(macOS)
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.minY + bounds.maxY)
            ctx.scaleBy(x: 1, y: -1)
        }
        #endif
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
    }
}
