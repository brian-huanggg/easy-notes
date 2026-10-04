import ExcalidrawKit

#if os(iOS)
import PencilKit
import UIKit

/// iPad / iPhone 的白板畫布（見 architecture/whiteboard.md）。
/// 下層：`structureHost` 裡的背景（網格 / 點）與 `BoardLayerTree`，以 transform 跟著 `PKCanvasView` 的 contentOffset / zoomScale。
/// 中層：透明的 `PKCanvasView`，負責手寫、捲動、縮放與所有觸控。
/// 上層：`overlayHost` 裡的 `SelectionOverlay`（螢幕座標）。
/// 結構元素的編輯交給 `BoardEditor`：這裡只把手勢換成畫布座標，並依工具切換 PencilKit。
///
/// 座標：場景座標（檔案）−`region.origin` = 內容座標（`PKCanvasView` 與筆畫）。筆畫只在載入與存檔時換算。
final class BoardCanvasView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UITextViewDelegate {
    let canvas = PKCanvasView()
    let tree = BoardLayerTree(drawsFreedraw: false)
    let overlay = SelectionOverlay()
    let pattern = BackgroundPattern()
    private(set) var lod: BoardLOD!
    /// 手寫模式的工具盤。墨水只放這四種（其他墨水存成 freedraw 會失真），加上橡皮擦、套索與尺
    let toolPicker = PKToolPicker(toolItems: [
        PKToolPickerInkingItem(type: .pen), PKToolPickerInkingItem(type: .pencil),
        PKToolPickerInkingItem(type: .marker), PKToolPickerInkingItem(type: .monoline),
        PKToolPickerEraserItem(type: .vector), PKToolPickerLassoItem(), PKToolPickerRulerItem(),
    ])

    private let document: BoardDocument
    private let editor: BoardEditor
    private let structureHost = UIView()
    private let overlayHost = UIView()
    /// LOD 快照有自己的 position，所以放在一個只負責 transform 的 layer 裡
    private let lodHost = PlainLayer()
    /// 目前套用的手寫模式（nil = 還沒套用）
    private var inking: Bool?
    /// 非手寫模式的拖曳（Pencil 與手指）；`canvas.panGestureRecognizer` 要等它失敗才捲動
    private let editPan = UIPanGestureRecognizer()
    /// 手寫模式下手指長按才拖曳元素
    private let longPress = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private var touchDown: (point: CGPoint, type: UITouch.TouchType)?
    /// 上一次點一下（雙擊判定：不用第二個 tap 手勢，單擊就不必等雙擊失敗才選取）
    private var lastTap: (time: CFTimeInterval, point: CGPoint)?
    /// 編輯中的文字框與開始編輯時的縮放倍率（之後的縮放用 transform，不改字型，組字中不打斷）
    private var textView: BoardTextView?
    private var textZoom: CGFloat = 1
    /// 拖曳中改到手寫（例如移動 frame 帶動筆畫）：操作結束後重新載入 PencilKit 的筆畫
    private var inkChanged = false
    private var region: CanvasRegion
    private var saveTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var didPlaceInitialView = false

    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 4

    init(document: BoardDocument, editor: BoardEditor) {
        self.document = document
        self.editor = editor
        region = CanvasRegion(covering: ElementGeometry.bounds(of: document.scene.liveElements))
        super.init(frame: .zero)

        // 結構元素的顏色是固定的（#1e1e1e 等），PencilKit 在深色模式會反轉筆畫顏色，所以畫布固定淺色
        overrideUserInterfaceStyle = .light
        backgroundColor = Self.background(of: document.scene)

        structureHost.isUserInteractionEnabled = false
        lod = BoardLOD(tree: tree, drawsFreedraw: false) { [document] in document.scene }
        lodHost.anchorPoint = .zero
        lodHost.addSublayer(lod.root)
        structureHost.layer.addSublayer(pattern.root)
        structureHost.layer.addSublayer(lodHost)
        structureHost.layer.addSublayer(tree.root)
        addSubview(structureHost)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.minimumZoomScale = Self.minZoom
        canvas.maximumZoomScale = Self.maxZoom
        // 回彈是 Core Animation 動畫，期間沒有逐幀回呼，結構層會與筆畫對不上
        canvas.bouncesZoom = false
        // 手勢分工：iPad 上 Pencil 書寫、手指捲動與縮放（不跟隨系統「僅使用 Apple Pencil 繪圖」設定，
        // 否則沒開那個設定時單指會畫出筆畫）。iPhone 通常沒有 Pencil，手指也能畫；模擬器沒有 Pencil
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .pencilOnly : .anyInput
        #endif
        canvas.contentSize = region.size
        canvas.drawing = contentDrawing()
        addSubview(canvas)
        overlayHost.isUserInteractionEnabled = false
        overlayHost.layer.addSublayer(overlay.root)
        addSubview(overlayHost)

        toolPicker.addObserver(canvas)
        // 「用手指繪圖」由 drawingPolicy 固定，不讓使用者在工具盤切換
        toolPicker.showsDrawingPolicyControls = false
        tree.cardPreview = { [weak document] in document?.cardPreviews[$0] }
        tree.setScene(document.scene)
        setUpGestures()
        editor.onChange = { [weak self] change in self?.editorDidChange(change) }
        editor.requestTextCommit = { [weak self] in self?.finishText() }

        // 外部寫入併進場景後：更新結構層、把新筆畫畫上去。存檔時筆畫與場景比對，沒變的元素不會被改動
        document.onExternalChange = { [weak self] in
            guard let self else { return }
            if let all = ElementGeometry.bounds(of: document.scene.liveElements),
               let next = region.expanded(toInclude: all) { apply(next) }
            canvas.drawing = contentDrawing()
            tree.setScene(document.scene)
            editor.sceneDidChange()
            lod.sceneChanged()
            updateVisible()
            scheduleWork()
            updateOverlay()
        }
        document.flushHandler = { [weak self] in self?.saveNow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        structureHost.frame = bounds
        canvas.frame = bounds
        overlayHost.frame = bounds
        if !didPlaceInitialView, bounds.width > 0 {
            didPlaceInitialView = true
            placeInitialView()
        }
        syncTransform()
        updateVisible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            tree.setContentsScale(screenScale * rasterScale)
            scheduleWork()
            editor.undoManager = canvas.undoManager
            toolPicker.setVisible(inking == true, forFirstResponder: canvas)
            // 放進視窗的同一輪 SwiftUI 還在調整階層，延到下一輪才成為 first responder（工具盤才會出現）
            DispatchQueue.main.async { [weak self] in self?.canvas.becomeFirstResponder() }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// 開啟時：縮放 1×，內容左上角（留一點邊）對齊畫面左上；空白板顯示場景原點
    private func placeInitialView() {
        let content = ElementGeometry.bounds(of: document.scene.liveElements)
        let target = content.map { CGPoint(x: $0.minX - 40, y: $0.minY - 40) } ?? CGPoint(x: -40, y: -40)
        canvas.contentOffset = region.toContent(target)
    }

    // MARK: 存檔

    /// 存檔時把筆畫換回場景座標
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let drawing = canvas.drawing.transformed(using: CGAffineTransform(translationX: region.origin.x, y: region.origin.y))
        document.commit { $0.update(from: drawing) }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        scheduleSave()
    }

    /// 停止操作 500 ms 後存檔（筆畫與結構操作共用）
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func contentDrawing() -> PKDrawing {
        document.scene.drawing.transformed(using: CGAffineTransform(translationX: -region.origin.x, y: -region.origin.y))
    }

    // MARK: 對齊與裁切

    /// 螢幕座標 = (場景座標 − origin) × zoom − contentOffset。在 scrollViewDidScroll / DidZoom 中同步設定，
    /// 與 PencilKit 的內容在同一個 CATransaction 提交，不會落後一幀
    private func syncTransform() {
        let z = canvas.zoomScale, o = canvas.contentOffset, origin = region.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: -origin.x * z - o.x, ty: -origin.y * z - o.y)
        for root in [tree.root, pattern.root, lodHost] {
            root.setAffineTransform(transform)
            root.position = .zero
        }
        pattern.update(visible: visibleSceneRect, zoom: z)
        CATransaction.commit()
        editor.zoom = z
        editor.visibleRect = visibleSceneRect
        updateOverlay()
        layoutText()
    }

    /// 畫布座標 → 螢幕座標（與結構層的 transform 相同）
    private var sceneToScreen: CGAffineTransform {
        let z = canvas.zoomScale, o = canvas.contentOffset, origin = region.origin
        return CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: -origin.x * z - o.x, ty: -origin.y * z - o.y)
    }

    /// 螢幕座標（這個 view）→ 畫布座標
    private func scenePoint(_ p: CGPoint) -> CGPoint {
        p.applying(sceneToScreen.inverted())
    }

    private func updateOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.update(editor, transform: sceneToScreen)
        CATransaction.commit()
    }

    /// 畫面看到的範圍（場景座標）
    var visibleSceneRect: CGRect {
        let z = canvas.zoomScale, o = canvas.contentOffset
        return CGRect(x: o.x / z + region.origin.x, y: o.y / z + region.origin.y,
                      width: bounds.width / z, height: bounds.height / z)
    }

    /// 只為畫面內（外加四分之一畫面的緩衝）的元素建立 layer
    private func updateVisible() {
        let rect = visibleSceneRect
        let buffer = max(rect.width, rect.height) * 0.25
        if tree.updateVisible(rect.insetBy(dx: -buffer, dy: -buffer)) { scheduleWork() }
        // 元素太多又縮得很小時改用快照；有選取或操作中不用（編輯結果要即時看到）
        let idle = editor.selection.isEmpty && !editor.isDragging && editor.textEditing == nil
        lod.viewChanged(visible: rect, zoom: canvas.zoomScale, screenScale: screenScale, idle: idle)
    }

    // MARK: 無限畫布

    /// 停止捲動後檢查是否接近邊緣（捲動中改 contentOffset 會干擾慣性）
    private func growIfNeeded() {
        guard let next = region.expanded(toShow: visibleSceneRect) else { return }
        apply(next)
    }

    /// 換成新的範圍：往左 / 上擴大時筆畫與 contentOffset 平移同樣的量，畫面不動
    private func apply(_ next: CanvasRegion) {
        let shift = CGPoint(x: region.origin.x - next.origin.x, y: region.origin.y - next.origin.y)
        let z = canvas.zoomScale
        let offset = canvas.contentOffset
        saveNow() // 先存目前的筆畫（用舊的 origin 換算）
        region = next
        // PKCanvasView 的 contentSize 是縮放後的大小（與 Apple 的 PencilKitDraw 範例相同）
        canvas.contentSize = CGSize(width: next.size.width * z, height: next.size.height * z)
        if shift != .zero {
            canvas.drawing = canvas.drawing.transformed(using: CGAffineTransform(translationX: shift.x, y: shift.y))
            canvas.contentOffset = CGPoint(x: offset.x + shift.x * z, y: offset.y + shift.y * z)
        }
        syncTransform()
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncTransform()
        updateVisible()
    }

    /// 縮放中不重新點陣化既有的 layer（沿用舊點陣，暫時模糊）；新建的 layer 用 min(目前倍率, 縮放倍率)
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncTransform()
        tree.setContentsScale(screenScale * rasterScale, immediate: false)
        updateVisible()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        tree.setContentsScale(screenScale * rasterScale)
        scheduleWork()
        growIfNeeded()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { growIfNeeded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        growIfNeeded()
    }

    // MARK: 分批工作

    private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    /// 點陣倍率 = 縮放倍率（0.25…4）
    private var rasterScale: CGFloat { min(max(canvas.zoomScale, Self.minZoom), Self.maxZoom) }

    /// 有分批工作才開 display link，做完就關（閒置時不跑任何計時器）
    private func scheduleWork() {
        guard displayLink == nil, window != nil, tree.hasPendingWork else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick() {
        updateVisible()
        tree.drainRaster()
        if !tree.hasPendingWork {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    // MARK: 工具

    /// 手寫模式：PencilKit 的手勢與工具盤開啟，Pencil 書寫、手指點選與長按拖曳。
    /// 關閉時停用 PencilKit 的手勢，Pencil 與手指都交給編輯器（碰到元素就拖曳、Pencil 在空白處框選）
    func apply(inking next: Bool) {
        guard next != inking else { return }
        inking = next
        canvas.drawingGestureRecognizer.isEnabled = next
        if next { canvas.tool = toolPicker.selectedTool }
        if window != nil {
            toolPicker.setVisible(next, forFirstResponder: canvas)
            // 工具盤綁在 first responder 上：文字框或工具列拿走之後要搶回來，工具盤才叫得出來
            if next, textView == nil { canvas.becomeFirstResponder() }
        }
        editPan.isEnabled = !next
        longPress.isEnabled = next
        // 手寫模式下 Pencil 點一下是畫點，只有手指點選
        tap.allowedTouchTypes = next ? [UITouch.TouchType.direct.rawValue as NSNumber]
            : [UITouch.TouchType.direct, .pencil].map { $0.rawValue as NSNumber }
    }

    func apply(background: BoardBackground) {
        guard background != pattern.style else { return }
        pattern.apply(background)
        syncTransform()
    }

    // MARK: 編輯器

    private func editorDidChange(_ change: BoardChange) {
        if change.structural {
            tree.setScene(document.scene)
        } else if !change.ids.isEmpty {
            tree.refresh(change.ids, in: document.scene)
        }
        if change.structural || change.finished { lod.sceneChanged() }
        updateVisible()
        if !change.ids.isEmpty, !inkChanged {
            inkChanged = document.scene.elements.contains { el in
                el["type"] as? String == "freedraw" && (el["id"] as? String).map(change.ids.contains) == true
            }
        }
        if change.finished {
            if inkChanged {
                inkChanged = false
                canvas.drawing = contentDrawing()
            }
            scheduleSave()
        }
        scheduleWork()
        updateOverlay()
        syncTextView()
    }

    // MARK: 文字

    /// 編輯器開始或放棄文字編輯時，建立或移除文字框
    private func syncTextView() {
        if let editing = editor.textEditing, textView == nil {
            startText(editing)
        } else if editor.textEditing == nil, textView != nil {
            removeTextView()
        }
    }

    /// 在元素上疊 `UITextView`：字級、行高、顏色、對齊與元素相同；編輯中隱藏該元素的 layer
    private func startText(_ editing: TextEditing) {
        let tv = BoardTextView()
        textZoom = canvas.zoomScale
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        let attributes = textAttributes(editing)
        tv.attributedText = NSAttributedString(string: editing.text, attributes: attributes)
        tv.typingAttributes = attributes
        tv.delegate = self
        tv.onEscape = { [weak self] in self?.finishText() }
        addSubview(tv)
        textView = tv
        tree.hiddenIDs = editing.id.map { [$0] } ?? []
        layoutText()
        tv.becomeFirstResponder()
    }

    /// 與 `ElementPainter.drawLines` 相同的排版：固定行高、字形在行高中垂直置中
    private func textAttributes(_ editing: TextEditing) -> [NSAttributedString.Key: Any] {
        let font = UIFont.systemFont(ofSize: editing.fontSize * textZoom)
        let line = editing.fontSize * editing.lineHeight * textZoom
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = line
        style.maximumLineHeight = line
        style.alignment = switch editing.align {
        case "center": .center
        case "right": .right
        default: .left
        }
        let color = SceneColor.parse(editing.color).map(UIColor.init(cgColor:)) ?? .black
        // 固定行高時多出來的空間在字形上方；往上移一半，與渲染器的垂直置中一致
        return [.font: font, .paragraphStyle: style, .foregroundColor: color,
                .baselineOffset: (line - (font.ascender - font.descender)) / 2]
    }

    /// 文字框的位置與大小跟著內容（排版與模型相同）、捲動與縮放
    private func layoutText() {
        guard let tv = textView, let editing = editor.textEditing else { return }
        let r = editing.rect(for: tv.text ?? "")
        // 獨立文字不換行：多留一個字寬給游標，文字框才不會比排版先換行
        let slack = editing.maxWidth == nil ? editing.fontSize : 0
        var frame = r
        frame.size.width += slack
        switch editing.align {
        case "center": frame.origin.x -= slack / 2
        case "right": frame.origin.x -= slack
        default: break
        }
        // 繞元素（文字或容器）中心旋轉
        let center = Geometry.rotate(CGPoint(x: frame.midX, y: frame.midY), around: CGPoint(x: r.midX, y: r.midY),
                                     by: editing.angle)
        tv.bounds = CGRect(x: 0, y: 0, width: frame.width * textZoom, height: frame.height * textZoom)
        tv.center = center.applying(sceneToScreen)
        let scale = canvas.zoomScale / textZoom
        tv.transform = CGAffineTransform(rotationAngle: editing.angle).scaledBy(x: scale, y: scale)
    }

    /// 結束編輯：交出文字框的內容（組字中的字直接確定），寫回場景
    func finishText() {
        guard let tv = textView else { return }
        tv.unmarkText()
        let text = tv.text ?? ""
        removeTextView()
        editor.endTextEditing(text)
        canvas.becomeFirstResponder() // 工具盤與白板的 Undo 回到畫布
        if inking == true { toolPicker.setVisible(true, forFirstResponder: canvas) }
    }

    private func removeTextView() {
        guard let tv = textView else { return }
        textView = nil
        tv.delegate = nil
        tv.resignFirstResponder()
        tv.removeFromSuperview()
        tree.hiddenIDs = []
    }

    func textViewDidChange(_ textView: UITextView) {
        layoutText()
    }

    /// 例如按了鍵盤的收合鍵
    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === self.textView { finishText() }
    }

    // MARK: 鍵盤（外接鍵盤）

    /// V R O A T F、Delete、⌘D、⌘A（見 architecture/whiteboard.md「4c：macOS 宿主、快捷鍵、LOD」）。
    /// 文字框編輯中不攔截，字母才打得進文字框
    override var keyCommands: [UIKeyCommand]? {
        guard textView == nil else { return [] }
        let tools: [(String, String)] = [("v", L("選取")), ("r", L("矩形")), ("o", L("橢圓")), ("a", L("箭頭")), ("t", L("文字")), ("f", "Frame")]
        var commands = tools.map { key, title in
            UIKeyCommand(title: title, action: #selector(handleKeyCommand(_:)), input: key, modifierFlags: [])
        }
        commands.append(UIKeyCommand(title: L("刪除"), action: #selector(handleKeyCommand(_:)),
                                     input: UIKeyCommand.inputDelete, modifierFlags: []))
        commands.append(UIKeyCommand(title: L("再製"), action: #selector(handleKeyCommand(_:)), input: "d", modifierFlags: .command))
        commands.append(UIKeyCommand(title: L("全選"), action: #selector(handleKeyCommand(_:)), input: "a", modifierFlags: .command))
        commands.append(UIKeyCommand(title: L("結束"), action: #selector(handleKeyCommand(_:)),
                                     input: UIKeyCommand.inputEscape, modifierFlags: []))
        return commands
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input,
              let shortcut = BoardShortcut(input, command: command.modifierFlags.contains(.command)) else { return }
        editor.perform(shortcut)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)): textView == nil && !editor.selection.isEmpty
        case #selector(paste(_:)): textView == nil && BoardPasteboard.hasContent
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) { editor.perform(.copy) }
    override func cut(_ sender: Any?) { editor.perform(.cut) }
    override func paste(_ sender: Any?) { editor.perform(.paste) }

    private func setUpGestures() {
        editPan.maximumNumberOfTouches = 1
        editPan.addTarget(self, action: #selector(handlePan(_:)))
        editPan.delegate = self
        canvas.addGestureRecognizer(editPan)
        canvas.panGestureRecognizer.require(toFail: editPan)

        longPress.minimumPressDuration = 0.35
        longPress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        longPress.addTarget(self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self
        canvas.addGestureRecognizer(longPress)

        tap.addTarget(self, action: #selector(handleTap(_:)))
        tap.delegate = self
        canvas.addGestureRecognizer(tap)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === editPan { touchDown = (touch.location(in: self), touch.type) }
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let inking else { return false }
        if g === editPan {
            // 第二根手指：交給捲動與縮放
            guard !inking, g.numberOfTouches <= 1, let down = touchDown else { return false }
            if editor.tool.creates || down.type == .pencil { return true }
            // 手指：碰到元素或控制點才拖曳，空白處捲動
            return editor.canGrab(at: scenePoint(down.point))
        }
        if g === longPress {
            return inking && editor.canGrab(at: scenePoint(g.location(in: self)))
        }
        return true
    }

    /// 點選與捲動、縮放可以同時辨識（點一下不會擋住之後的捲動）
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === tap && (other === canvas.panGestureRecognizer || other === canvas.pinchGestureRecognizer)
    }

    /// 點一下：編輯文字中 → 結束編輯；雙擊文字或形狀 → 編輯文字（空白處雙擊新增文字，
    /// 手寫模式只編輯既有的）；其他交給編輯器
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let inking else { return }
        if textView != nil {
            finishText()
            lastTap = nil
            return
        }
        let screen = g.location(in: self), p = scenePoint(screen)
        let now = CACurrentMediaTime()
        let isDouble = lastTap.map { now - $0.time < 0.35 && hypot(screen.x - $0.point.x, screen.y - $0.point.y) < 24 }
            ?? false
        lastTap = isDouble ? nil : (now, screen)
        if isDouble, !inking, editor.tool == .select {
            editor.editText(at: p)
        } else if isDouble, inking, let hit = editor.element(at: p) {
            editor.editText(of: hit)
        } else {
            editor.tap(at: p, extend: g.modifierFlags.contains(.shift))
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        drive(g, start: touchDown?.point)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        drive(g, start: nil)
    }

    /// 拖曳手勢 → 編輯器。`start` = 手指放下的位置（拖曳手勢在移動一段距離後才開始）
    private func drive(_ g: UIGestureRecognizer, start: CGPoint?) {
        let p = scenePoint(g.location(in: self))
        switch g.state {
        case .began:
            guard editor.begin(at: start.map(scenePoint) ?? p, extend: g.modifierFlags.contains(.shift)) else {
                g.state = .cancelled
                return
            }
            editor.drag(to: p)
        case .changed: editor.drag(to: p)
        case .ended: editor.end(at: p)
        case .cancelled, .failed: editor.cancel()
        default: break
        }
    }

    // MARK: 背景

    static func background(of scene: ExcalidrawScene) -> UIColor {
        let hex = (scene.raw["appState"] as? [String: Any])?["viewBackgroundColor"] as? String
        return SceneColor.parse(hex ?? "#ffffff").map(UIColor.init(cgColor:)) ?? .white
    }
}

/// CADisplayLink 會強引用 target；經由弱引用的 proxy，畫布關閉時不會被留住
private final class DisplayLinkProxy: NSObject {
    weak var view: BoardCanvasView?

    init(_ view: BoardCanvasView) { self.view = view }

    @MainActor @objc func tick() { view?.tick() }
}
#endif
