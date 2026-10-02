#if os(macOS)
import AppKit
import QuartzCore

/// macOS 的白板畫布（見 Architecture「4c：macOS 宿主、快捷鍵、LOD」）。沒有 `PKCanvasView`，
/// 所以不用 `NSScrollView`，自己管平移與縮放：螢幕座標 = (場景座標 − `origin`) × `zoom`。
/// 層級與 iOS 相同：背景 / LOD 快照 / 結構層（`sceneHost` 套同一個 transform）→ 選取外框（螢幕座標）→ 文字框。
/// 手寫由結構層畫（只能看，不能選取或編輯）。結構元素的編輯交給 `BoardEditor`：這裡只把滑鼠與鍵盤換成畫布座標與快捷鍵。
final class BoardMacCanvasView: NSView, NSTextViewDelegate, NSUserInterfaceValidations {
    let tree = BoardLayerTree(drawsFreedraw: true)
    let overlay = SelectionOverlay()
    let pattern = BackgroundPattern()
    private(set) var lod: BoardLOD!

    private let document: BoardDocument
    private let editor: BoardEditor
    private let sceneHost = PlainLayer()
    /// 結構操作的 Undo 堆疊（Mac 沒有筆畫，不與別處共用）
    private let history = UndoManager()

    /// 畫面左上角的場景座標與縮放倍率
    private var origin = CGPoint.zero
    private var zoom: CGFloat = 1
    private var didPlaceInitialView = false

    private var saveTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?

    /// 目前這次按下：位置（螢幕座標）、按下前的選取、是否移動過、編輯器是否開始了操作
    private struct Down {
        var point: CGPoint
        var selection: Set<String>
        var extend: Bool
        var moved = false
        var began: Bool
    }
    private var down: Down?

    private var textView: BoardTextView?
    private var textZoom: CGFloat = 1

    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 4
    /// 按下後移動超過這個距離（螢幕點）才算拖曳
    static let dragThreshold: CGFloat = 3

    init(document: BoardDocument, editor: BoardEditor) {
        self.document = document
        self.editor = editor
        super.init(frame: .zero)
        lod = BoardLOD(tree: tree, drawsFreedraw: true) { [document] in document.scene }

        wantsLayer = true
        // 結構元素的顏色是固定的（#1e1e1e 等），所以畫布固定淺色，與 iOS 相同
        appearance = NSAppearance(named: .aqua)
        layer?.backgroundColor = Self.background(of: document.scene)
        layer?.masksToBounds = true

        sceneHost.anchorPoint = .zero
        for child in [pattern.root, lod.root, tree.root] { sceneHost.addSublayer(child) }
        layer?.addSublayer(sceneHost)
        layer?.addSublayer(overlay.root)

        tree.setScene(document.scene)
        editor.undoManager = history
        editor.onChange = { [weak self] change in self?.editorDidChange(change) }
        editor.requestTextCommit = { [weak self] in self?.finishText() }

        // 外部寫入併進場景後：更新結構層。存檔時場景本身就是真相，沒變的元素不會被改動
        document.onExternalChange = { [weak self] in
            guard let self else { return }
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

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { history }

    // MARK: 版面

    override func layout() {
        super.layout()
        if !didPlaceInitialView, bounds.width > 0 {
            didPlaceInitialView = true
            placeInitialView()
        }
        syncTransform()
        updateVisible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            tree.setContentsScale(screenScale * rasterScale)
            scheduleWork()
            // 放進視窗的同一輪 SwiftUI 還在調整階層，延到下一輪才成為 first responder（快捷鍵才收得到）
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.firstResponder === window || window.firstResponder == nil else { return }
                window.makeFirstResponder(self)
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tree.setContentsScale(screenScale * rasterScale)
        scheduleWork()
    }

    /// 開啟時：縮放 1×，內容左上角（留一點邊）對齊畫面左上；空白板顯示場景原點
    private func placeInitialView() {
        let content = ElementGeometry.bounds(of: document.scene.liveElements)
        origin = content.map { CGPoint(x: $0.minX - 40, y: $0.minY - 40) } ?? CGPoint(x: -40, y: -40)
    }

    // MARK: 存檔

    /// 手寫由結構層畫、本來就在場景裡，存檔只需要把場景寫出
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        document.commit()
    }

    /// 停止操作 500 ms 後存檔
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: 座標與裁切

    private var sceneToScreen: CGAffineTransform {
        CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: -origin.x * zoom, ty: -origin.y * zoom)
    }

    private func scenePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x / zoom, y: origin.y + p.y / zoom)
    }

    /// 畫面看到的範圍（場景座標）
    var visibleSceneRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: bounds.width / zoom, height: bounds.height / zoom)
    }

    private func syncTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sceneHost.setAffineTransform(sceneToScreen)
        sceneHost.position = .zero
        sceneHost.bounds = .zero
        pattern.update(visible: visibleSceneRect, zoom: zoom)
        overlay.root.frame = bounds
        CATransaction.commit()
        editor.zoom = zoom
        editor.visibleRect = visibleSceneRect
        updateOverlay()
        layoutText()
    }

    private func updateOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.update(editor, transform: sceneToScreen)
        CATransaction.commit()
    }

    /// 只為畫面內（外加四分之一畫面的緩衝）的元素建立 layer；元素太多又縮得很小時改用 LOD 快照
    private func updateVisible() {
        let rect = visibleSceneRect
        let buffer = max(rect.width, rect.height) * 0.25
        if tree.updateVisible(rect.insetBy(dx: -buffer, dy: -buffer)) { scheduleWork() }
        let idle = editor.selection.isEmpty && !editor.isDragging && editor.textEditing == nil
        lod.viewChanged(visible: rect, zoom: zoom, screenScale: screenScale, idle: idle)
    }

    /// 平移 / 縮放後統一的更新
    private func viewDidChange() {
        syncTransform()
        updateVisible()
    }

    // MARK: 縮放與平移

    private var screenScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// 點陣倍率 = 縮放倍率（0.25…4）
    private var rasterScale: CGFloat { min(max(zoom, Self.minZoom), Self.maxZoom) }

    /// 以 `anchor`（這個 view 的座標）為中心縮放，anchor 下的場景點不動
    private func setZoom(_ next: CGFloat, around anchor: CGPoint) {
        let z = min(max(next, Self.minZoom), Self.maxZoom)
        guard z != zoom else { return }
        let point = scenePoint(anchor)
        zoom = z
        origin = CGPoint(x: point.x - anchor.x / z, y: point.y - anchor.y / z)
        // 縮放中不重新點陣化既有的 layer；停止後才分批重畫（與 iOS 相同）
        tree.setContentsScale(screenScale * rasterScale, immediate: false)
        viewDidChange()
        settleAfterZoom()
    }

    /// 停止縮放 150 ms 後重設點陣倍率
    private func settleAfterZoom() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            tree.setContentsScale(screenScale * rasterScale)
            scheduleWork()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.option) {
            let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
            setZoom(zoom * exp(event.scrollingDeltaY * step), around: convert(event.locationInWindow, from: nil))
        } else {
            origin.x -= event.scrollingDeltaX / zoom
            origin.y -= event.scrollingDeltaY / zoom
            viewDidChange()
        }
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    // MARK: 分批工作

    /// 有分批工作才開 display link，做完就關（閒置時不跑任何計時器）
    private func scheduleWork() {
        guard displayLink == nil, window != nil, tree.hasPendingWork else { return }
        let link = displayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
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
        if change.finished { scheduleSave() }
        updateVisible()
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

    /// 在元素上疊 `NSTextView`：字級、行高、顏色、對齊與元素相同；編輯中隱藏該元素的 layer
    private func startText(_ editing: TextEditing) {
        let tv = BoardTextView(frame: .zero)
        textZoom = zoom
        tv.drawsBackground = false
        tv.isRichText = true // 純文字模式無法設 baselineOffset；貼上改走 pasteAsPlainText
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        let attributes = textAttributes(editing)
        tv.textStorage?.setAttributedString(NSAttributedString(string: editing.text, attributes: attributes))
        tv.typingAttributes = attributes
        tv.delegate = self
        tv.onEscape = { [weak self] in self?.finishText() }
        addSubview(tv)
        textView = tv
        tree.hiddenIDs = editing.id.map { [$0] } ?? []
        layoutText()
        window?.makeFirstResponder(tv)
    }

    /// 與 `ElementPainter.drawLines` 相同的排版：固定行高、字形在行高中垂直置中
    private func textAttributes(_ editing: TextEditing) -> [NSAttributedString.Key: Any] {
        let font = NSFont.systemFont(ofSize: editing.fontSize * textZoom)
        let line = editing.fontSize * editing.lineHeight * textZoom
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = line
        style.maximumLineHeight = line
        style.alignment = switch editing.align {
        case "center": .center
        case "right": .right
        default: .left
        }
        let color = SceneColor.parse(editing.color).flatMap(NSColor.init(cgColor:)) ?? .black
        return [.font: font, .paragraphStyle: style, .foregroundColor: color,
                .baselineOffset: (line - (font.ascender - font.descender)) / 2]
    }

    /// 文字框的位置與大小跟著內容（排版與模型相同）、平移與縮放。
    /// `bounds` 維持開始編輯時的倍率、`frame` 跟著縮放，內容自動縮放，不改字型（組字中不打斷）
    private func layoutText() {
        guard let tv = textView, let editing = editor.textEditing else { return }
        let r = editing.rect(for: tv.string)
        // 獨立文字不換行：多留一個字寬給游標，文字框才不會比排版先換行
        let slack = editing.maxWidth == nil ? editing.fontSize : 0
        var frame = r
        frame.size.width += slack
        switch editing.align {
        case "center": frame.origin.x -= slack / 2
        case "right": frame.origin.x -= slack
        default: break
        }
        let center = Geometry.rotate(CGPoint(x: frame.midX, y: frame.midY), around: CGPoint(x: r.midX, y: r.midY),
                                     by: editing.angle).applying(sceneToScreen)
        let size = CGSize(width: frame.width * zoom, height: frame.height * zoom)
        tv.frameCenterRotation = 0
        tv.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        tv.bounds = CGRect(x: 0, y: 0, width: frame.width * textZoom, height: frame.height * textZoom)
        // 父 view 是翻轉的：正的角度（順時針，與 Excalidraw 相同）要轉成 AppKit 的逆時針度數
        tv.frameCenterRotation = -editing.angle * 180 / .pi
    }

    /// 結束編輯：交出文字框的內容（組字中的字直接確定），寫回場景
    func finishText() {
        guard let tv = textView else { return }
        tv.unmarkText()
        let text = tv.string
        removeTextView()
        editor.endTextEditing(text)
        window?.makeFirstResponder(self)
    }

    private func removeTextView() {
        guard let tv = textView else { return }
        textView = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        tree.hiddenIDs = []
        if window?.firstResponder === tv { window?.makeFirstResponder(self) }
    }

    func textDidChange(_ notification: Notification) {
        layoutText()
    }

    /// 例如按了 Tab 或點到別的控制項
    func textDidEndEditing(_ notification: Notification) {
        if notification.object as? BoardTextView === textView { finishText() }
    }

    // MARK: 滑鼠

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textView != nil {
            finishText()
            return
        }
        let screen = location(of: event), p = scenePoint(screen)
        let extend = event.modifierFlags.contains(.shift)
        // 雙擊文字或形狀 → 編輯文字（空白處雙擊新增文字）；文字工具點一下就編輯
        if (event.clickCount >= 2 && editor.tool == .select) || editor.tool == .text {
            if editor.tool == .text { editor.tap(at: p) } else { editor.editText(at: p) }
            return
        }
        let before = editor.selection
        let began = editor.begin(at: p, extend: extend)
        down = Down(point: screen, selection: before, extend: extend, began: began)
        updateVisible()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = down else { return }
        let screen = location(of: event)
        if !current.moved {
            guard hypot(screen.x - current.point.x, screen.y - current.point.y) >= Self.dragThreshold else { return }
            current.moved = true
            down = current
        }
        if current.began { editor.drag(to: scenePoint(screen)) }
    }

    /// 沒有移動 = 點選：取消這次操作、還原選取，改走 `tap`（Shift 加減選才正確）
    override func mouseUp(with event: NSEvent) {
        guard let current = down else { return }
        down = nil
        let p = scenePoint(location(of: event))
        if current.began, current.moved {
            editor.end(at: p)
        } else {
            if current.began { editor.cancel() }
            editor.selection = current.selection
            editor.tap(at: p, extend: current.extend)
        }
        updateVisible()
    }

    // MARK: 鍵盤與選單

    private func shortcut(for event: NSEvent) -> BoardShortcut? {
        guard let characters = event.charactersIgnoringModifiers else { return nil }
        let flags = event.modifierFlags
        return BoardShortcut(characters, command: flags.contains(.command), shift: flags.contains(.shift),
                             control: flags.contains(.control), option: flags.contains(.option))
    }

    override func keyDown(with event: NSEvent) {
        if let shortcut = shortcut(for: event), editor.perform(shortcut) { return }
        super.keyDown(with: event)
    }

    /// ⌘ 組合鍵比主選單先到：自己處理 ⌘D / ⌘A / ⌘C / ⌘X / ⌘V（文字框是 first responder 時不會進來）
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command),
              let shortcut = shortcut(for: event), editor.perform(shortcut) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    @objc func copy(_ sender: Any?) { editor.perform(.copy) }
    @objc func cut(_ sender: Any?) { editor.perform(.cut) }
    @objc func paste(_ sender: Any?) { editor.perform(.paste) }
    @objc func delete(_ sender: Any?) { editor.perform(.delete) }
    @objc override func selectAll(_ sender: Any?) { editor.perform(.selectAll) }
    @objc func duplicate(_ sender: Any?) { editor.perform(.duplicate) }

    /// 編輯選單的復原 / 重做：走結構操作的堆疊（`NSWindow` 預設用視窗自己的 undoManager）
    @objc func undo(_ sender: Any?) { history.undo() }
    @objc func redo(_ sender: Any?) { history.redo() }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): history.canUndo
        case #selector(redo(_:)): history.canRedo
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)):
            !editor.selection.isEmpty
        default: true
        }
    }

    // MARK: 背景

    static func background(of scene: ExcalidrawScene) -> CGColor {
        let hex = (scene.raw["appState"] as? [String: Any])?["viewBackgroundColor"] as? String
        return SceneColor.parse(hex ?? "#ffffff") ?? SceneColor.rgb(0xffffff)
    }

    /// 離開白板
    func close() {
        finishText()
        saveNow()
        displayLink?.invalidate()
        displayLink = nil
        settleTask?.cancel()
        lod.deactivate()
    }
}

/// CADisplayLink 會強引用 target；經由弱引用的 proxy，畫布關閉時不會被留住
private final class DisplayLinkProxy: NSObject {
    weak var view: BoardMacCanvasView?

    init(_ view: BoardMacCanvasView) { self.view = view }

    @MainActor @objc func tick() { view?.tick() }
}
#endif
