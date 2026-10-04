import CoreGraphics
import EasyNotesUI
import ExcalidrawKit
import Foundation
import QuartzCore

/// 編輯器的結構層：每個畫面內的元素一個 layer，放在 `root` 底下（畫布座標，未縮放）。
/// 宿主（iOS 的 `PKCanvasView`、macOS 的 `NSView`）只設定 `root` 的 transform 與可見範圍。
///
/// 規則照 Spike S3（見 architecture/whiteboard.md）：
/// - 只為可見範圍（宿主加一圈緩衝）內的元素建立 layer；建立與重新點陣化每次有上限，剩下的交給之後的幀。
/// - 形狀、線、箭頭、frame 外框是 `CAShapeLayer`（向量，縮放時不必重新點陣化）；
///   文字、圖片、手寫、佔位框由 `ElementPainter` 畫進點陣 layer，倍率跟著縮放。
/// - 所有 layer 都沒有隱含動畫（點陣 `contents` 換內容時淡入淡出會成為殘影）。
@MainActor
final class BoardLayerTree {
    let root: CALayer = PlainLayer()

    /// iOS 的手寫由 `PKCanvasView` 畫，結構層不畫 freedraw；macOS 沒有 PencilKit 畫布，由結構層畫
    let drawsFreedraw: Bool
    /// 建立與重新點陣化每次最多處理的 layer 數
    static let batchSize = 120

    /// LOD 啟用中（畫面改由 `BoardLOD` 的點陣快照顯示）：不建立任何 layer，已建立的移除；
    /// 關閉時宿主要再呼叫 `updateVisible` 分批重建
    var lodActive = false {
        didSet { if lodActive != oldValue, !visibleRect.isNull { updateVisible(visibleRect) } }
    }

    /// 點陣 layer 的 `contentsScale`（螢幕倍率 × 點陣倍率）。新建的 layer 直接用它；
    /// 改變時既有的 layer 排入佇列，由 `drainRaster` 分批重畫
    private(set) var contentsScale: CGFloat = 2

    /// 不顯示的元素（例如正在用原生文字框編輯的文字）
    var hiddenIDs: Set<String> = [] {
        didSet {
            for id in hiddenIDs.symmetricDifference(oldValue) { layers[id]?.isHidden = hiddenIDs.contains(id) }
        }
    }

    private struct Item {
        var element: Element
        var bounds: CGRect
        var order: Int
        /// version + versionNonce：合併後可能 version 相同、nonce 不同
        var stamp: String
    }

    /// 筆記卡片依路徑向文件取預覽（標題 + 前幾行）；有預覽的卡片由這裡畫內容，綁定的標題文字隱藏
    var cardPreview: (String) -> DocumentPreview? = { _ in nil }
    /// 卡片元素 id → 檔案路徑（`setScene` 時重建）
    private var cardPaths: [String: String] = [:]

    private var items: [Item] = []
    private var position: [String: Int] = [:]
    private var layers: [String: ElementLayer] = [:]
    private var painter = ElementPainter(files: [:])
    private var fileIDs: Set<String> = []
    private var visibleRect: CGRect = .null
    private var rasterQueue: [String] = []

    init(drawsFreedraw: Bool) {
        self.drawsFreedraw = drawsFreedraw
        root.anchorPoint = .zero
    }

    /// 目前有 layer 的元素數（HUD、測試用）
    var layerCount: Int { layers.count }

    func layer(for id: String) -> CALayer? { layers[id] }

    /// 是否還有沒做完的分批工作（建立 layer 或重新點陣化），宿主據此決定是否在下一幀繼續
    var hasPendingWork: Bool { needsMoreLayers || !rasterQueue.isEmpty }
    private var needsMoreLayers = false

    // MARK: 場景

    /// 換上新的場景：依 id + version 比對，只重建有變的元素；順序改變時重排 layer。
    /// 可見範圍內新出現的元素依 `batchSize` 分批建立。
    func setScene(_ scene: ExcalidrawScene) {
        let files = scene.raw["files"] as? [String: Any] ?? [:]
        if Set(files.keys) != fileIDs {
            fileIDs = Set(files.keys)
            painter = ElementPainter(files: files)
        }

        let live = scene.liveElements.filter { drawsFreedraw || $0.type != .freedraw }
        cardPaths = [:]
        for el in live where el.customData != nil {
            if let path = scene.noteCardPath(el.id) { cardPaths[el.id] = path }
        }
        var newItems: [Item] = []
        newItems.reserveCapacity(live.count)
        var changed: Set<String> = []
        for (order, el) in live.enumerated() {
            let stamp = "\(el.version)-\(el.versionNonce)" + cardKey(el)
            if let i = position[el.id], items[i].stamp != stamp { changed.insert(el.id) }
            newItems.append(Item(element: el, bounds: ElementGeometry.bounds(el), order: order, stamp: stamp))
        }
        // frame 變了：子元素的裁切跟著變
        let changedFrames = newItems.filter { changed.contains($0.element.id) && $0.element.type == .frame }
            .map(\.element.id)
        if !changedFrames.isEmpty {
            let frames = Set(changedFrames)
            for item in newItems where item.element.frameId.map(frames.contains) == true { changed.insert(item.element.id) }
        }

        let orderChanged = newItems.map(\.element.id) != items.map(\.element.id)
        items = newItems
        position = Dictionary(items.enumerated().map { ($1.element.id, $0) }, uniquingKeysWith: { a, _ in a })

        withoutAnimation {
            for (id, layer) in layers {
                guard let i = position[id] else {
                    layer.removeFromSuperlayer()
                    layers[id] = nil
                    continue
                }
                if changed.contains(id) {
                    let fresh = makeLayer(items[i])
                    root.replaceSublayer(layer, with: fresh)
                    layers[id] = fresh
                } else {
                    layer.order = items[i].order
                }
            }
            if orderChanged {
                root.sublayers = (root.sublayers ?? []).sorted { a, b in
                    ((a as? ElementLayer)?.order ?? .max) < ((b as? ElementLayer)?.order ?? .max)
                }
            }
        }
        if !visibleRect.isNull { updateVisible(visibleRect) }
    }

    /// 拖曳中：只更新 `ids` 的元素（順序不變），省掉 `setScene` 對整個場景的排序與比對。
    /// 有新元素或改到 frame（子元素的裁切跟著變）時改走 `setScene`。
    func refresh(_ ids: Set<String>, in scene: ExcalidrawScene) {
        guard !ids.isEmpty else { return }
        var updates: [(Int, Element)] = []
        for raw in scene.elements {
            guard let id = raw["id"] as? String, ids.contains(id) else { continue }
            let el = Element(raw: raw)
            if el.type == .freedraw, !drawsFreedraw { continue }
            guard let i = position[id], !el.isDeleted, el.type != .frame else { setScene(scene); return }
            updates.append((i, el))
        }
        withoutAnimation {
            for (i, el) in updates {
                items[i] = Item(element: el, bounds: ElementGeometry.bounds(el), order: items[i].order,
                                stamp: "\(el.version)-\(el.versionNonce)")
                if let layer = layers[el.id] {
                    let fresh = makeLayer(items[i])
                    root.replaceSublayer(layer, with: fresh)
                    layers[el.id] = fresh
                }
            }
        }
        // 移進或移出可見範圍
        if !visibleRect.isNull { updateVisible(visibleRect) }
    }

    /// 卡片（或卡片的標題文字）目前預覽的指紋：預覽到了或改了，layer 就要重建
    private func cardKey(_ el: Element) -> String {
        guard !cardPaths.isEmpty, let path = cardPaths[el.id] ?? el.containerId.flatMap({ cardPaths[$0] }),
              let preview = cardPreview(path)
        else { return "" }
        return "-c\(preview.hashValue)"
    }

    // MARK: 可見範圍

    /// 與 `rect` 相交的元素數（LOD 的門檻判斷；不看 layer 有沒有建立）
    func visibleCount(in rect: CGRect) -> Int {
        items.reduce(0) { $0 + (rect.intersects($1.bounds) ? 1 : 0) }
    }

    /// 建立可見範圍內的 layer、移除範圍外的。一次最多建立 `batchSize` 個，還有剩回傳 true（下一幀再呼叫）
    @discardableResult
    func updateVisible(_ rect: CGRect, budget: Int = BoardLayerTree.batchSize) -> Bool {
        visibleRect = rect
        var budget = budget
        var more = false
        let appendOnly = layers.isEmpty
        withoutAnimation {
            for item in items {
                let id = item.element.id
                let inside = !lodActive && rect.intersects(item.bounds)
                if inside, layers[id] == nil {
                    guard budget > 0 else { more = true; continue }
                    budget -= 1
                    let layer = makeLayer(item)
                    if appendOnly { root.addSublayer(layer) } else { insert(layer) }
                    layers[id] = layer
                } else if !inside, let layer = layers.removeValue(forKey: id) {
                    layer.removeFromSuperlayer()
                }
            }
        }
        needsMoreLayers = more
        return more
    }

    /// 依元素順序插入（`root.sublayers` 依 order 排序，二分搜尋）
    private func insert(_ layer: ElementLayer) {
        let subs = root.sublayers ?? []
        var lo = 0, hi = subs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ((subs[mid] as? ElementLayer)?.order ?? .max) < layer.order { lo = mid + 1 } else { hi = mid }
        }
        root.insertSublayer(layer, at: UInt32(lo))
    }

    // MARK: 點陣倍率

    /// 設定點陣 layer 的倍率。`immediate` = 新建的 layer 直接用，既有的排入佇列分批重畫；
    /// 縮放途中宿主傳 false：只讓新建的 layer 用 min(目前, 新倍率)，結束縮放後再呼叫一次
    func setContentsScale(_ scale: CGFloat, immediate: Bool = true) {
        guard immediate else {
            contentsScale = min(contentsScale, scale)
            return
        }
        contentsScale = scale
        rasterQueue = layers.compactMap { id, layer in
            layer.painted.contains { $0.contentsScale != scale } ? id : nil
        }
    }

    /// 重畫一批點陣 layer；還有剩回傳 true
    @discardableResult
    func drainRaster(budget: Int = BoardLayerTree.batchSize) -> Bool {
        guard !rasterQueue.isEmpty else { return false }
        let batch = rasterQueue.suffix(budget)
        rasterQueue.removeLast(batch.count)
        withoutAnimation {
            for id in batch {
                // 文字在同一個 transaction 內重畫，不留舊點陣
                for layer in layers[id]?.painted ?? [] {
                    layer.contentsScale = contentsScale
                    layer.setNeedsDisplay()
                    layer.displayIfNeeded()
                }
            }
        }
        return !rasterQueue.isEmpty
    }

    // MARK: 建立 layer

    private func makeLayer(_ item: Item) -> ElementLayer {
        let el = item.element
        let box = ElementGeometry.paddedBox(el)
        let center = ElementGeometry.center(el)
        let layer = ElementLayer()
        layer.order = item.order
        layer.elementID = el.id
        // bounds 的原點 = 畫布座標，所以子 layer 的路徑直接用畫布座標
        layer.bounds = box
        layer.anchorPoint = CGPoint(x: (center.x - box.minX) / max(box.width, 1),
                                    y: (center.y - box.minY) / max(box.height, 1))
        layer.position = center
        if el.angle != 0 { layer.setAffineTransform(CGAffineTransform(rotationAngle: el.angle)) }
        layer.opacity = Float(((el.raw["opacity"] as? NSNumber)?.doubleValue ?? 100) / 100)
        layer.isHidden = hiddenIDs.contains(el.id)

        switch el.type {
        case .rectangle, .diamond, .ellipse:
            addShape(ElementGeometry.outline(el), el, to: layer, fill: true, join: .miter)
            if let path = cardPaths[el.id], let preview = cardPreview(path) {
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let rect = el.rect.standardized
                addPainted(el, to: layer) { _, _, ctx, _ in
                    NoteCardPainter.draw(name: name, preview: preview, in: rect, ctx: ctx)
                }
            }
        case .line, .arrow:
            addShape(ElementGeometry.linePath(el), el, to: layer, fill: ElementGeometry.isClosedLine(el), join: .round)
            addArrowheads(el, to: layer)
        case .frame:
            let outline = ShapeLayer()
            outline.frame = box
            outline.bounds = box
            outline.path = ElementGeometry.outline(el)
            outline.fillColor = SceneColor.parse(el.raw["backgroundColor"] as? String ?? "transparent")
            outline.strokeColor = SceneColor.frameStroke
            outline.lineWidth = 1.5
            layer.addSublayer(outline)
            addPainted(el, to: layer) { painter, el, ctx, _ in painter.drawFrameTitle(el, in: ctx) }
        case .text, .image, .freedraw, .unknown:
            addPainted(el, to: layer) { painter, el, ctx, scale in painter.drawContent(el, in: ctx, pixelScale: scale) }
            // 卡片的標題文字留在檔案裡給 excalidraw.com，App 內由卡片自己畫
            if let container = el.containerId, let path = cardPaths[container], cardPreview(path) != nil {
                layer.isHidden = true
            }
        }
        layer.mask = frameMask(for: el, bounds: item.bounds, box: box)
        return layer
    }

    private func addShape(_ path: CGPath, _ el: Element, to layer: ElementLayer, fill: Bool, join: CAShapeLayerLineJoin) {
        let shape = ShapeLayer()
        shape.frame = layer.bounds
        shape.bounds = layer.bounds
        shape.path = path
        shape.fillColor = fill ? SceneColor.parse(el.raw["backgroundColor"] as? String ?? "transparent") : nil
        let width = ElementGeometry.strokeWidth(el)
        if width > 0, let stroke = SceneColor.parse(el.raw["strokeColor"] as? String ?? "#1e1e1e") {
            shape.strokeColor = stroke
            shape.lineWidth = width
        } else {
            shape.strokeColor = nil
        }
        shape.lineJoin = join
        shape.lineCap = .round
        switch el.raw["strokeStyle"] as? String {
        case "dashed":
            shape.lineDashPattern = [8, NSNumber(value: 8 + width)]
            shape.lineCap = .butt
        case "dotted":
            shape.lineDashPattern = [1.5, NSNumber(value: 6 + width)]
        default: break
        }
        layer.addSublayer(shape)
    }

    /// 箭頭頭部一律實線；填色與只描邊的部件分成兩個 layer
    private func addArrowheads(_ el: Element, to layer: ElementLayer) {
        let heads = ElementGeometry.arrowheads(el)
        guard !heads.isEmpty, let color = SceneColor.parse(el.raw["strokeColor"] as? String ?? "#1e1e1e") else { return }
        for fill in [false, true] {
            let path = CGMutablePath()
            for head in heads where head.fill == fill { path.addPath(head.path) }
            guard !path.isEmpty else { continue }
            let shape = ShapeLayer()
            shape.frame = layer.bounds
            shape.bounds = layer.bounds
            shape.path = path
            shape.strokeColor = color
            shape.fillColor = fill ? color : nil
            shape.lineWidth = ElementGeometry.strokeWidth(el)
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
        }
    }

    private func addPainted(_ el: Element, to layer: ElementLayer,
                            draw: @escaping @Sendable (ElementPainter, Element, CGContext, CGFloat) -> Void) {
        let painted = PaintedLayer(element: el, painter: painter, draw: draw)
        painted.frame = layer.bounds
        painted.bounds = layer.bounds
        painted.contentsScale = contentsScale
        painted.setNeedsDisplay()
        layer.addSublayer(painted)
        layer.painted.append(painted)
    }

    /// frame 內的元素依 frame 範圍裁切。只在元素超出 frame 時才加 mask（mask 需要離屏合成）
    private func frameMask(for el: Element, bounds: CGRect, box: CGRect) -> CALayer? {
        guard let frameID = el.frameId, let i = position[frameID], items[i].element.type == .frame else { return nil }
        let frameRect = items[i].element.rect.standardized
        guard !frameRect.contains(bounds) else { return nil }
        // mask 在元素 layer 的座標系（未旋轉），frame 範圍要反向旋轉
        let mask = ShapeLayer()
        mask.frame = box
        mask.bounds = box
        var inverse = ElementGeometry.rotation(el).inverted()
        mask.path = CGPath(rect: frameRect, transform: &inverse)
        mask.fillColor = SceneColor.rgb(0)
        return mask
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - layer 類別

/// 沒有隱含動畫的 layer
class PlainLayer: CALayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

final class ShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

/// 一個元素：子 layer 是形狀或點陣內容
final class ElementLayer: PlainLayer {
    var order = 0
    var elementID = ""
    /// 需要依點陣倍率重畫的子 layer
    var painted: [PaintedLayer] = []
}

/// 以 `ElementPainter` 畫內容的點陣 layer（bounds 的原點 = 畫布座標）
final class PaintedLayer: PlainLayer {
    private let element: Element?
    private let painter: ElementPainter?
    private let drawBody: (@Sendable (ElementPainter, Element, CGContext, CGFloat) -> Void)?

    init(element: Element, painter: ElementPainter,
         draw: @escaping @Sendable (ElementPainter, Element, CGContext, CGFloat) -> Void) {
        self.element = element
        self.painter = painter
        drawBody = draw
        super.init()
        needsDisplayOnBoundsChange = true
    }

    /// Core Animation 複製 layer（presentation layer）時使用
    override init(layer: Any) {
        let other = layer as? PaintedLayer
        element = other?.element
        painter = other?.painter
        drawBody = other?.drawBody
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        guard let element, let painter, let drawBody else { return }
        // ElementPainter 假設 y 向下。iOS 的 layer context 本來就是；macOS 要自己翻轉
        #if os(macOS)
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.minY + bounds.maxY)
            ctx.scaleBy(x: 1, y: -1)
        }
        #endif
        drawBody(painter, element, ctx, contentsScale)
    }
}
