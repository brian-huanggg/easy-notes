import CoreGraphics
import Foundation
import Observation

/// 選取外框上的控制點
enum SelectionHandle: Equatable {
    /// 縮放：dx / dy ∈ -1, 0, 1（-1 = 左 / 上，1 = 右 / 下，0 = 這個方向不動）
    case resize(dx: Int, dy: Int)
    /// 單一線或箭頭的端點
    case end(ArrowEnd)
}

/// 選取外框：單一元素是它未旋轉的外框加 `angle`；多選是整體範圍（不旋轉）
struct SelectionFrame: Equatable {
    var rect: CGRect
    var angle: Double
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// 箭頭端點要綁上去的形狀；`side` = 吸附到的連接點（`Geometry.sides` 的索引，nil = 沒吸附）
struct BindPick: Equatable {
    var id: String
    var side: Int?

    /// 綁定時寫入的 `fixedPoint`（nil = 依放開位置計算）
    var fixedPoint: CGPoint? { side.map { Geometry.sides[$0].ratio } }
}

/// 編輯器通知宿主的變動
struct BoardChange {
    /// 內容有變的元素
    var ids: Set<String> = []
    /// 新增、刪除或順序改變：宿主要整個 `setScene`，否則只更新 `ids` 的 layer
    var structural = false
    /// 一個操作結束：宿主排存檔
    var finished = false
}

/// 白板的編輯核心（見 architecture/whiteboard.md4c 編輯核心）。不依賴平台：
/// 宿主把觸控 / 滑鼠事件換成畫布座標交給它，它修改 `BoardDocument` 的場景、維護選取，
/// 每個操作結束時在 `undoManager` 註冊一筆可復原的紀錄。
@MainActor @Observable
final class BoardEditor {
    let document: BoardDocument

    var tool: BoardTool = .select {
        didSet { if tool != oldValue { toolChanged() } }
    }

    /// 手寫模式（iOS 畫筆按鈕）：Pencil 交給 PencilKit，手指點選、長按才拖曳，空白處不框選
    var inking = false {
        didSet { if inking != oldValue { toolChanged() } }
    }

    var selection: Set<String> = [] {
        didSet { if selection != oldValue { onChange?(BoardChange()) } }
    }

    /// 框選中的範圍（畫布座標）
    @ObservationIgnored private(set) var marquee: CGRect?
    /// 套索選取經過的點（畫布座標；放開時自動閉合）
    @ObservationIgnored private(set) var lasso: [CGPoint]?
    /// 空白處拖曳的範圍選取方式（宿主依 App 偏好設定）
    @ObservationIgnored var selectionShape: SelectionShape = .rectangle
    /// 拖曳箭頭端點時，放開就會綁上去的形狀與連接點
    @ObservationIgnored private(set) var bindTarget: BindPick?

    /// 正在用原生文字框編輯的文字（見 `BoardEditor+Text`）
    var textEditing: TextEditing?

    /// 樣式面板上次改的值，新元素沿用（只在記憶體，見 `BoardEditor+Style`）
    @ObservationIgnored var currentStyle: [StyleProperty: StyleChange] = [:]
    /// 透明度滑桿拖曳中
    @ObservationIgnored var stylePreviewing = false

    /// 目前的縮放倍率：容差與控制點大小是螢幕上固定的點數
    @ObservationIgnored var zoom: CGFloat = 1
    /// 畫面看到的範圍（畫布座標）；插入圖片放在它的中央
    @ObservationIgnored var visibleRect: CGRect = .null
    /// 宿主提供：結束文字框的編輯（取得文字框內容後呼叫 `endTextEditing`）
    @ObservationIgnored var requestTextCommit: (() -> Void)?
    /// 換工具而結束文字編輯中
    @ObservationIgnored var switchingTool = false
    /// 宿主提供（iOS：`PKCanvasView` 的 undoManager，與筆畫共用一個堆疊）
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored var onChange: ((BoardChange) -> Void)?

    /// 控制點的觸控半徑（螢幕點）
    static let handleRadius: CGFloat = 16
    /// 點選元素的容差（螢幕點）
    static let hitTolerance: CGFloat = 8
    /// 箭頭端點吸附到連接點的距離（螢幕點）
    static let snapRadius: CGFloat = 14
    /// 箭頭端點與形狀的距離（Excalidraw 的 binding gap）
    static let bindingGap: Double = 5
    /// 套索相鄰兩點的最小距離（螢幕點）
    static let lassoSpacing: CGFloat = 3
    /// 拖曳超過這個距離（螢幕點）才建立元素
    static let createThreshold: CGFloat = 6
    /// 再製的位移
    static let duplicateOffset = CGPoint(x: 10, y: 10)

    private enum Gesture {
        case move(start: CGPoint, applied: CGPoint)
        case resize(dx: Int, dy: Int, frame: SelectionFrame, originals: [Element])
        case end(id: String, end: ArrowEnd, original: Element)
        case marquee(start: CGPoint, base: Set<String>)
        case lasso(base: Set<String>)
        case create(tool: BoardTool, start: CGPoint, id: String?, startTarget: BindPick?)
    }

    @ObservationIgnored private var gesture: Gesture?
    /// 操作開始時的元素，結束時與目前比對出 Undo 紀錄
    @ObservationIgnored var gestureBefore: [[String: Any]] = []
    @ObservationIgnored private var gestureWrites = 0
    /// 操作開始時的選取（復原時選回它）
    @ObservationIgnored var gestureSelection: Set<String> = []

    init(document: BoardDocument) {
        self.document = document
    }

    private var tolerance: Double { Self.hitTolerance / zoom }

    // MARK: 查詢

    /// 最上層被點到、可以選取的元素（形狀內的文字回傳容器）
    func element(at p: CGPoint) -> String? {
        let scene = document.scene
        for el in scene.liveElements.reversed() where HitTest.isSelectable(el) {
            guard HitTest.hits(el, p, tolerance: tolerance, selected: selection.contains(el.id)) else { continue }
            if let container = el.containerId, scene.element(container)?.isDeleted == false { return container }
            return el.id
        }
        return nil
    }

    /// 選到 `id` 時實際選取的元素：最外層群組的所有成員（形狀內的文字不算，跟著容器）
    func selectionGroup(of id: String) -> Set<String> {
        guard let el = document.scene.element(id), let group = el.groupIds.last else { return [id] }
        return Set(document.scene.liveElements
            .filter { $0.groupIds.contains(group) && $0.containerId == nil && HitTest.isSelectable($0) }
            .map(\.id))
    }

    var selectedElements: [Element] {
        document.scene.liveElements.filter { selection.contains($0.id) }
    }

    var selectionFrame: SelectionFrame? {
        let els = selectedElements
        if els.count == 1, let el = els.first {
            return SelectionFrame(rect: ElementGeometry.box(el), angle: el.angle)
        }
        let rect = els.reduce(CGRect.null) { $0.union(ElementGeometry.box($1).applying(ElementGeometry.rotation($1))) }
        return rect.isNull ? nil : SelectionFrame(rect: rect, angle: 0)
    }

    /// 控制點與它們的位置（畫布座標）。單一兩點的線或箭頭是兩個端點；文字與圖片只有四個角（等比例）
    var handles: [(handle: SelectionHandle, point: CGPoint)] {
        let els = selectedElements
        guard let frame = selectionFrame else { return [] }
        if els.count == 1, let el = els.first, el.type == .arrow || el.type == .line, el.points.count == 2 {
            let pts = el.absolutePoints
            return [(.end(.start), pts[0]), (.end(.end), pts[1])]
        }
        let cornersOnly = els.count == 1 && (els[0].type == .text || els[0].type == .image)
        var result: [(SelectionHandle, CGPoint)] = []
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                if cornersOnly, dx == 0 || dy == 0 { continue }
                let local = CGPoint(x: frame.rect.midX + Double(dx) * frame.rect.width / 2,
                                    y: frame.rect.midY + Double(dy) * frame.rect.height / 2)
                result.append((.resize(dx: dx, dy: dy), Geometry.rotate(local, around: frame.center, by: frame.angle)))
            }
        }
        return result
    }

    func handle(at p: CGPoint) -> SelectionHandle? {
        let radius = Self.handleRadius / zoom
        return handles
            .map { ($0.handle, hypot($0.point.x - p.x, $0.point.y - p.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// 這一點有東西可以抓（控制點、元素、多選的範圍內）。宿主用來決定手指要拖曳還是捲動
    func canGrab(at p: CGPoint) -> Bool {
        handle(at: p) != nil || element(at: p) != nil || insideMultiSelection(p)
    }

    private func insideMultiSelection(_ p: CGPoint) -> Bool {
        selection.count > 1 && (selectionFrame?.rect.contains(p) ?? false)
    }

    /// 箭頭端點可以綁上去的形狀（最上層）
    func bindableShape(at p: CGPoint, excluding id: String? = nil) -> String? {
        document.scene.liveElements.reversed().first { el in
            el.id != id && !el.locked && HitTest.bindable(el, p, tolerance: tolerance)
        }?.id
    }

    /// 箭頭端點在 `p` 時要綁上去的形狀：最近的連接點在吸附距離內就吸附，否則是 `p` 下方最上層的形狀
    func bindPick(at p: CGPoint, excluding id: String? = nil) -> BindPick? {
        let radius = Self.snapRadius / zoom
        var best: (pick: BindPick, distance: Double)?
        for el in document.scene.liveElements.reversed()
        where el.id != id && !el.locked && el.type.isBindableShape && el.containerId == nil {
            guard ElementGeometry.bounds(el).insetBy(dx: -radius, dy: -radius).contains(p) else { continue }
            for (i, side) in Geometry.sides.enumerated() {
                let c = Geometry.point(in: el, ratio: side.ratio)
                let d = hypot(c.x - p.x, c.y - p.y)
                if d <= radius, d < best?.distance ?? .infinity { best = (BindPick(id: el.id, side: i), d) }
            }
        }
        if let best { return best.pick }
        return bindableShape(at: p, excluding: id).map { BindPick(id: $0) }
    }

    /// 拖曳中端點顯示的位置：吸附到連接點時就在連接點外 `gap` 處
    func snapped(_ p: CGPoint, to pick: BindPick?) -> CGPoint {
        guard let pick, let side = pick.side, let shape = document.scene.element(pick.id) else { return p }
        return Geometry.sideEndpoint(shape, side: side, gap: Self.bindingGap)
    }

    // MARK: 點選

    /// 點一下：選取被點到的元素（`extend` = Shift，加入或移除），空白處取消選取。
    /// 文字工具：編輯點到的文字或形狀內的文字，空白處新增文字。建立工具不處理
    func tap(at p: CGPoint, extend: Bool = false) {
        guard gesture == nil, textEditing == nil, !tool.creates else { return }
        if tool == .text { editText(at: p); return }
        guard let hit = element(at: p) else {
            if !extend { selection = [] }
            return
        }
        let group = selectionGroup(of: hit)
        if extend {
            selection = selection.isSuperset(of: group) ? selection.subtracting(group) : selection.union(group)
        } else {
            selection = group
        }
    }

    func selectAll() {
        selection = Set(document.scene.liveElements.filter { HitTest.isSelectable($0) && $0.containerId == nil }.map(\.id))
    }

    func clearSelection() {
        selection = []
    }

    // MARK: 拖曳

    /// 開始拖曳。選取工具：控制點 → 縮放、元素 → 移動、空白處 → 框選；建立工具：建立元素；
    /// 手寫模式（手指長按）不框選。回傳是否開始了一個操作。
    @discardableResult
    func begin(at p: CGPoint, extend: Bool = false) -> Bool {
        if gesture != nil { cancel() }
        if textEditing != nil { finishTextEditing() }
        gestureBefore = document.scene.elements
        gestureWrites = document.writeCount
        defer { gestureSelection = selection }

        if tool.creates {
            selection = []
            gesture = .create(tool: tool, start: p, id: nil, startTarget: tool == .arrow ? bindPick(at: p) : nil)
            return true
        }
        if let handle = handle(at: p), let frame = selectionFrame {
            let originals = selectedElements
            switch handle {
            case let .resize(dx, dy):
                gesture = .resize(dx: dx, dy: dy, frame: frame, originals: originals)
            case let .end(end):
                guard let el = originals.first else { return false }
                gesture = .end(id: el.id, end: end, original: el)
            }
            return true
        }
        if let hit = element(at: p) {
            let group = selectionGroup(of: hit)
            if !selection.isSuperset(of: group) { selection = extend ? selection.union(group) : group }
            gesture = .move(start: p, applied: .zero)
            return true
        }
        if insideMultiSelection(p) {
            gesture = .move(start: p, applied: .zero)
            return true
        }
        guard tool == .select, !inking else { return false }
        let base = extend ? selection : []
        selection = base
        if selectionShape == .lasso {
            lasso = [p]
            gesture = .lasso(base: base)
        } else {
            gesture = .marquee(start: p, base: base)
        }
        return true
    }

    func drag(to p: CGPoint) {
        guard let gesture else { return }
        switch gesture {
        case let .move(start, applied):
            let delta = CGPoint(x: p.x - start.x, y: p.y - start.y)
            let ids = selection
            perform { $0.move(ids, dx: delta.x - applied.x, dy: delta.y - applied.y) }
            self.gesture = .move(start: start, applied: delta)

        case let .resize(dx, dy, frame, originals):
            perform { Self.resize(&$0, originals, frame: frame, dx: dx, dy: dy, to: p) }

        case let .end(id, end, original):
            let pick = original.type == .arrow ? bindPick(at: p, excluding: id) : nil
            var pts = original.absolutePoints
            pts[end == .start ? 0 : pts.count - 1] = snapped(p, to: pick)
            perform { $0.mutate(id) { $0.setAbsolutePoints(pts) } }
            bindTarget = pick

        case let .marquee(start, base):
            let rect = Self.rect(start, p)
            marquee = rect
            let inside = document.scene.liveElements.filter { el in
                HitTest.isSelectable(el) && el.containerId == nil && rect.contains(ElementGeometry.bounds(el))
            }
            selection = inside.reduce(base) { $0.union(selectionGroup(of: $1.id)) }
            onChange?(BoardChange())

        case let .lasso(base):
            guard var pts = lasso else { return }
            if let last = pts.last, hypot(p.x - last.x, p.y - last.y) < Self.lassoSpacing / zoom { return }
            pts.append(p)
            lasso = pts
            selection = lassoed(pts).reduce(base) { $0.union(selectionGroup(of: $1)) }
            onChange?(BoardChange())

        case let .create(tool, start, id, startTarget):
            let pick = tool == .arrow ? bindPick(at: p, excluding: id) : nil
            let from = snapped(start, to: startTarget), to = snapped(p, to: pick)
            if let id {
                perform { scene in
                    scene.mutate(id) { el in
                        if tool == .arrow {
                            el.setAbsolutePoints([from, to])
                        } else {
                            let r = Self.rect(start, p)
                            el.x = r.minX; el.y = r.minY; el.width = r.width; el.height = r.height
                        }
                    }
                }
            } else {
                guard hypot(p.x - start.x, p.y - start.y) >= Self.createThreshold / zoom else { return }
                var el = tool == .arrow ? Self.make(tool, from: from, to: to) : Self.make(tool, from: start, to: p)
                applyCurrentStyle(to: &el)
                perform { $0.insert(el) }
                self.gesture = .create(tool: tool, start: start, id: el.id, startTarget: startTarget)
                selection = [el.id]
            }
            if tool == .arrow { bindTarget = pick }
        }
    }

    /// 結束拖曳：箭頭綁定、frame 收進範圍內的元素，並註冊一筆 Undo
    func end(at p: CGPoint) {
        guard gesture != nil else { return }
        drag(to: p)
        guard let gesture else { return }
        self.gesture = nil
        let target = bindTarget
        bindTarget = nil
        marquee = nil

        let name: String
        switch gesture {
        case .move: name = "移動"
        case .resize: name = "縮放"
        case let .end(id, end, original):
            name = "移動端點"
            if original.type == .arrow {
                perform { scene in
                    if let target {
                        scene.bind(arrow: id, end, to: target.id, fixedPoint: target.fixedPoint, gap: Self.bindingGap)
                    } else {
                        scene.unbind(arrow: id, end)
                    }
                }
            }
        case .marquee:
            onChange?(BoardChange())
            return
        case .lasso:
            lasso = nil
            onChange?(BoardChange())
            return
        case let .create(tool, _, id, startTarget):
            guard let id else { return }
            name = tool.title
            if tool == .arrow {
                perform { scene in
                    if let startTarget {
                        scene.bind(arrow: id, .start, to: startTarget.id, fixedPoint: startTarget.fixedPoint, gap: Self.bindingGap)
                    }
                    if let target {
                        scene.bind(arrow: id, .end, to: target.id, fixedPoint: target.fixedPoint, gap: Self.bindingGap)
                    }
                }
            } else if tool == .frame, let frame = document.scene.element(id) {
                let inside = document.scene.liveElements.filter { el in
                    el.id != id && el.type != .frame && el.frameId == nil && frame.rect.contains(ElementGeometry.bounds(el))
                }
                perform { $0.setFrame(Set(inside.map(\.id)), to: id) }
            }
            self.tool = .select
            selection = [id]
        }
        recordUndo(name)
    }

    /// 取消拖曳（例如第二根手指放上來開始縮放）：回到開始前的狀態，不留 Undo
    func cancel() {
        guard gesture != nil else { return }
        gesture = nil
        bindTarget = nil
        marquee = nil
        lasso = nil
        let (undo, _) = Self.snapshots(from: gestureBefore, to: document.scene.elements)
        guard !undo.isEmpty else { onChange?(BoardChange()); return }
        if document.writeCount == gestureWrites {
            // 中途沒存過檔：直接換回原本的元素，version 不變、新建的元素不留墓碑
            let before = gestureBefore
            perform { $0.raw["elements"] = before }
        } else {
            perform { $0.restore(undo) }
        }
        selection = selection.filter { document.scene.element($0)?.isDeleted == false }
    }

    var isDragging: Bool { gesture != nil }

    /// 取樣點全部落在套索多邊形（自動閉合）內的元素
    func lassoed(_ pts: [CGPoint]) -> [String] {
        guard pts.count >= 3 else { return [] }
        let polygon = CGMutablePath()
        polygon.addLines(between: pts)
        polygon.closeSubpath()
        let hull = polygon.boundingBoxOfPath
        return document.scene.liveElements.filter { el in
            HitTest.isSelectable(el) && el.containerId == nil && hull.contains(ElementGeometry.bounds(el))
                && HitTest.samplePoints(el).allSatisfy { polygon.contains($0) }
        }.map(\.id)
    }

    // MARK: 選取的操作

    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        operation("刪除", select: { _ in [] }) { $0.delete(ids) }
    }

    func duplicateSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        operation("再製", select: roots) { $0.duplicate(ids, offset: Self.duplicateOffset) }
    }

    func copySelection() -> Data? {
        document.scene.clipboardData(selection)
    }

    /// 貼上 Excalidraw 剪貼簿，中心放在 `center`；不是 Excalidraw 剪貼簿回傳 false
    @discardableResult
    func paste(_ data: Data, center: CGPoint) -> Bool {
        operation("貼上", select: { $0.map(roots) }) { $0.paste(data, center: center) } != nil
    }

    /// 外部變動、筆畫 Undo 之後：移除已刪除的選取
    func sceneDidChange() {
        if gesture != nil { cancel() }
        let alive = selection.filter { id in document.scene.element(id).map { !$0.isDeleted } ?? false }
        if alive != selection { selection = alive }
    }

    func roots(_ ids: [String]) -> Set<String> {
        Set(ids.filter { document.scene.element($0)?.containerId == nil })
    }

    private func toolChanged() {
        if gesture != nil { cancel() }
        if textEditing != nil { finishTextEditing(switchingTool: true) }
        if tool.creates { selection = [] }
    }

    // MARK: 修改與 Undo

    /// 修改場景（只改記憶體），通知宿主哪些元素變了
    @discardableResult
    func perform<T>(finished: Bool = false, _ body: (inout ExcalidrawScene) -> T) -> T {
        let before = document.scene.elements
        let result = document.edit(body)
        var change = Self.changes(from: before, to: document.scene.elements)
        change.finished = finished
        onChange?(change)
        return result
    }

    /// 一次完成的操作（刪除、再製、貼上、插入圖片）：修改、通知、註冊 Undo。
    /// `select` 依結果決定新的選取（nil = 不變），在註冊 Undo 之前設定，重做時才會選回它
    @discardableResult
    func operation<T>(_ name: String, select: (T) -> Set<String>? = { _ in nil },
                      _ body: (inout ExcalidrawScene) -> T) -> T {
        if gesture != nil { cancel() }
        if stylePreviewing { endStylePreview() }
        if textEditing != nil { finishTextEditing() }
        gestureBefore = document.scene.elements
        gestureSelection = selection
        let result = perform(body)
        if let next = select(result) { selection = next }
        recordUndo(name)
        return result
    }

    /// 比對操作前後，註冊 Undo，通知宿主排存檔
    func recordUndo(_ name: String) {
        let (undo, redo) = Self.snapshots(from: gestureBefore, to: document.scene.elements)
        gestureBefore = []
        onChange?(BoardChange(finished: true))
        guard !undo.isEmpty, let undoManager else { return }
        let record = UndoRecord(undo: undo, redo: redo, name: name,
                                undoSelection: gestureSelection, redoSelection: selection)
        undoManager.beginUndoGrouping()
        register(record, in: undoManager)
        undoManager.endUndoGrouping()
    }

    private func register(_ record: UndoRecord, in undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.revert(record) }
        }
        undoManager.setActionName(record.name)
    }

    /// 復原 / 重做：寫回紀錄中的內容（version 繼續遞增），再註冊反方向的紀錄
    private func revert(_ record: UndoRecord) {
        if gesture != nil { cancel() }
        if textEditing != nil { finishTextEditing() }
        perform(finished: true) { $0.restore(record.undo) }
        selection = record.undoSelection.filter { document.scene.element($0)?.isDeleted == false }
        if let undoManager { register(record.reversed, in: undoManager) }
    }

    // MARK: 計算

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private static func make(_ tool: BoardTool, from a: CGPoint, to b: CGPoint) -> Element {
        let r = rect(a, b)
        switch tool {
        case .ellipse: return .ellipse(x: r.minX, y: r.minY, width: r.width, height: r.height)
        case .arrow: return .arrow(from: a, to: b)
        case .frame: return .frame(x: r.minX, y: r.minY, width: r.width, height: r.height)
        default: return .rectangle(x: r.minX, y: r.minY, width: r.width, height: r.height)
        }
    }

    /// 拖曳控制點：`frame` 是開始時的選取外框，`q` 換到它未旋轉的座標系。對邊（角）固定、最小 1、不翻轉
    static func resized(_ r: CGRect, dx: Int, dy: Int, to q: CGPoint, keepAspect: Bool) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if dx == 1 { maxX = max(q.x, minX + 1) } else if dx == -1 { minX = min(q.x, maxX - 1) }
        if dy == 1 { maxY = max(q.y, minY + 1) } else if dy == -1 { minY = min(q.y, maxY - 1) }
        if keepAspect, dx != 0, dy != 0, r.width > 0, r.height > 0 {
            let s = max((maxX - minX) / r.width, (maxY - minY) / r.height)
            if dx == 1 { maxX = minX + r.width * s } else { minX = maxX - r.width * s }
            if dy == 1 { maxY = minY + r.height * s } else { minY = maxY - r.height * s }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 單一元素在自身座標系縮放（旋轉後對角仍固定）；多選依整體範圍換算每個元素。都從原始元素計算
    private static func resize(_ scene: inout ExcalidrawScene, _ originals: [Element], frame: SelectionFrame,
                               dx: Int, dy: Int, to p: CGPoint) {
        let c0 = frame.center
        let q = Geometry.rotate(p, around: c0, by: -frame.angle)
        if originals.count == 1, let el = originals.first {
            let keep = el.type == .text || el.type == .image
            var r = resized(frame.rect, dx: dx, dy: dy, to: q, keepAspect: keep)
            if frame.angle != 0 {
                // 新外框繞舊中心轉回去後的中心，就是新元素（繞自己中心旋轉）的中心
                let c = Geometry.rotate(CGPoint(x: r.midX, y: r.midY), around: c0, by: frame.angle)
                r.origin = CGPoint(x: c.x - r.width / 2, y: c.y - r.height / 2)
            }
            scene.resize(el.id, to: r, from: el)
            return
        }
        let old = frame.rect
        let r = resized(old, dx: dx, dy: dy, to: q, keepAspect: false)
        let sx = old.width > 0 ? r.width / old.width : 1, sy = old.height > 0 ? r.height / old.height : 1
        for el in originals {
            let b = ElementGeometry.box(el)
            let c = CGPoint(x: r.minX + (b.midX - old.minX) * sx, y: r.minY + (b.midY - old.minY) * sy)
            let w = b.width * sx, h = b.height * sy
            scene.resize(el.id, to: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), from: el)
        }
        scene.rebindArrows(movedIDs: Set(originals.map(\.id)))
    }

    // MARK: 比對

    private static func stamp(_ raw: [String: Any]) -> [Int] {
        [(raw["version"] as? NSNumber)?.intValue ?? 0, (raw["versionNonce"] as? NSNumber)?.intValue ?? 0]
    }

    private static func byID(_ elements: [[String: Any]]) -> [String: [String: Any]] {
        Dictionary(elements.compactMap { el in (el["id"] as? String).map { ($0, el) } }, uniquingKeysWith: { a, _ in a })
    }

    /// 依 version + versionNonce 找出變動的元素；新增、刪除或 index 改變算結構變動
    static func changes(from old: [[String: Any]], to new: [[String: Any]]) -> BoardChange {
        let before = byID(old)
        var change = BoardChange(structural: old.count != new.count)
        for el in new {
            guard let id = el["id"] as? String else { continue }
            guard let o = before[id] else { change.ids.insert(id); change.structural = true; continue }
            guard stamp(o) != stamp(el) else { continue }
            change.ids.insert(id)
            if (o["isDeleted"] as? Bool ?? false) != (el["isDeleted"] as? Bool ?? false)
                || (o["index"] as? String) != (el["index"] as? String) { change.structural = true }
        }
        return change
    }

    /// 操作前後有變的元素各自的內容（nil = 當時不存在）
    static func snapshots(from old: [[String: Any]], to new: [[String: Any]])
        -> (undo: ExcalidrawScene.Snapshot, redo: ExcalidrawScene.Snapshot) {
        let before = byID(old)
        var undo: ExcalidrawScene.Snapshot = [:], redo: ExcalidrawScene.Snapshot = [:]
        for el in new {
            guard let id = el["id"] as? String else { continue }
            let o = before[id]
            if let o, stamp(o) == stamp(el) { continue }
            // 不能用 `undo[id] = o`：o 為 nil 時是移除這個 key
            undo.updateValue(o, forKey: id)
            redo.updateValue(el, forKey: id)
        }
        return (undo, redo)
    }
}

/// 一筆結構操作的 Undo 紀錄（UndoManager 的 handler 要求 Sendable；只在主執行緒使用）
private final class UndoRecord: @unchecked Sendable {
    let undo: ExcalidrawScene.Snapshot
    let redo: ExcalidrawScene.Snapshot
    let name: String
    let undoSelection: Set<String>
    let redoSelection: Set<String>

    init(undo: ExcalidrawScene.Snapshot, redo: ExcalidrawScene.Snapshot, name: String,
         undoSelection: Set<String>, redoSelection: Set<String>) {
        self.undo = undo; self.redo = redo; self.name = name
        self.undoSelection = undoSelection; self.redoSelection = redoSelection
    }

    var reversed: UndoRecord {
        UndoRecord(undo: redo, redo: undo, name: name, undoSelection: redoSelection, redoSelection: undoSelection)
    }
}
