import ExcalidrawKit
import Foundation

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
}

#if os(macOS)
import AppKit
import PDFKit

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

// MARK: - overlay：滑過、點選、拖曳、右鍵選單

extension PageOverlayView {
    static let minStickySize: Double = 40

    /// 最上層、包含這個點的便利貼（overlay 座標）
    func sticky(at viewPoint: CGPoint) -> Element? {
        let p = pagePoint(viewPoint)
        if let hovered = chrome?.stickyID, let el = scene.element(hovered), !el.isDeleted,
           handleRect(for: el).contains(viewPoint) { return el }
        return scene.liveElements.reversed().first { $0.type == .rectangle && $0.rect.standardized.contains(p) }
    }

    /// overlay 1 點在視窗上的大小：外框與縮放點在任何縮放倍率下都維持相同的螢幕大小
    private var onScreenScale: CGFloat {
        max(convert(NSSize(width: 1, height: 0), to: nil).width, 0.01)
    }

    /// 縮放點：頁面座標的右下角（旋轉頁上依顯示位置）
    func handleRect(for el: Element) -> CGRect {
        let corner = CGPoint(x: el.rect.standardized.maxX, y: el.rect.standardized.maxY).applying(pageToView)
        let size = 14 / onScreenScale
        return CGRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size)
    }

    // MARK: 滑過

    func stickyMouseMoved(_ event: NSEvent) {
        guard drag == nil, host?.editing?.overlay !== self else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let el = sticky(at: p) else { hideChrome(); return }
        showChrome(for: el)
        (handleRect(for: el).contains(p) ? NSCursor.frameResize(position: .bottomRight, directions: .all) : .openHand).set()
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
        if chrome == nil { addSubview(view); chrome = view }
        view.stickyID = el.id
        view.lineWidth = 1.5 / onScreenScale
        view.handleSize = 10 / onScreenScale
        view.padding = pad
        view.frame = r.insetBy(dx: -pad, dy: -pad)
        view.needsDisplay = true
    }

    // MARK: 點選與拖曳

    func stickyMouseDown(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let el = sticky(at: p) else { return }
        host?.endEditing()
        if event.clickCount >= 2 {
            hideChrome()
            host?.beginEditing(el.id, on: self)
        } else {
            drag = StickyDrag(id: el.id, mode: handleRect(for: el).contains(p) ? .resize : .move, start: p, original: el)
        }
    }

    func stickyMouseDragged(_ event: NSEvent) {
        guard var drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if drag.preview == nil {
            let preview = StickyPreviewView(frame: bounds)
            preview.pageToView = pageToView
            addSubview(preview, positioned: .below, relativeTo: chrome)
            hiddenElements.formUnion(scene.stickyIDs(drag.id))
            drag.preview = preview
        }
        let (scene, rect) = dragged(drag, to: p)
        drag.preview?.scene = scene.only(scene.stickyIDs(drag.id))
        if let el = scene.element(drag.id) { showChrome(for: el, rect: rect) }
        self.drag = drag
        (drag.mode == .move ? NSCursor.closedHand : NSCursor.frameResize(position: .bottomRight, directions: .all)).set()
    }

    func stickyMouseUp(_ event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        guard let preview = drag.preview else { return }
        let p = convert(event.locationInWindow, from: nil)
        let (_, rect) = dragged(drag, to: p)
        let ids = scene.stickyIDs(drag.id)
        // 先寫入新位置（仍隱藏），再取消隱藏：只重畫新位置，便利貼不會先閃回原處
        if let document = host?.document, rect != drag.original.rect.standardized {
            document.edit(page: pageIndex) { scene in
                switch drag.mode {
                case .move: scene.move([drag.id], dx: rect.minX - drag.original.x, dy: rect.minY - drag.original.y)
                case .resize: scene.resize(drag.id, to: rect, from: drag.original)
                }
            }
            document.commit()
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
            let rect = CGRect(x: r.minX, y: r.minY, width: max(r.width + b.x - a.x, Self.minStickySize),
                              height: max(r.height + b.y - a.y, Self.minStickySize))
            scene.resize(drag.id, to: rect, from: drag.original)
            return (scene, scene.element(drag.id)?.rect.standardized ?? rect)
        }
    }

    func stickyMenu(_ event: NSEvent) -> NSMenu? {
        guard let el = sticky(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let menu = NSMenu()
        menu.addItem(StickyMenuItem("編輯") { [weak self] in
            guard let self else { return }
            host?.beginEditing(el.id, on: self)
        })
        menu.addItem(StickyMenuItem("刪除") { [weak self] in
            guard let self, let document = host?.document else { return }
            host?.endEditing()
            document.edit(page: pageIndex) { $0.delete([el.id]) }
            document.commit()
        })
        return menu
    }
}

/// 拖曳中的便利貼：`NSView.draw` 同步繪製（分塊的標註層是非同步畫的，移動時會缺塊）
final class StickyPreviewView: NSView {
    var pageToView = CGAffineTransform.identity
    var scene = ExcalidrawScene() { didSet { renderer = SceneRenderer(scene: scene); needsDisplay = true } }
    private var renderer: SceneRenderer?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderer, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.concatenate(pageToView)
        renderer.draw(in: ctx, pixelScale: hypot(ctx.ctm.a, ctx.ctm.b))
    }
}

/// 滑過的便利貼：外框 + 右下角縮放點
final class StickyChromeView: NSView {
    var stickyID: String?
    var lineWidth: CGFloat = 1.5
    var handleSize: CGFloat = 10
    /// frame 比便利貼大這麼多（縮放點突出在外）
    var padding: CGFloat = 8

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: padding, dy: padding)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: box)
        outline.lineWidth = lineWidth
        outline.stroke()
        let knob = NSBezierPath(ovalIn: CGRect(x: box.maxX - handleSize / 2, y: box.maxY - handleSize / 2,
                                               width: handleSize, height: handleSize))
        NSColor.white.setFill()
        knob.fill()
        knob.lineWidth = lineWidth
        knob.stroke()
    }
}

/// 以 closure 處理的選單項目
@MainActor
private final class StickyMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

// MARK: - 畫布：新增與文字編輯

/// 編輯中的便利貼文字
struct StickyEditing {
    let id: String
    weak var overlay: PageOverlayView?
    let textView: StickyTextView
}

extension PDFReaderCanvas {
    /// 在目前頁可見範圍的中央新增一張便利貼並開始編輯
    func addSticky() {
        endEditing()
        guard let index = currentPageIndex, let overlay = overlays[index] else { return }
        let visible = overlay.visibleRect.isEmpty ? overlay.bounds : overlay.visibleRect
        let size = overlay.geometry.size, half = PDFStickies.size / 2
        let c = overlay.pagePoint(CGPoint(x: visible.midX, y: visible.midY))
        let x = min(max(c.x - half, 0), max(size.width - PDFStickies.size, 0))
        let y = min(max(c.y - half, 0), max(size.height - PDFStickies.size, 0))
        let el = Element.stickyNote(x: x, y: y, size: PDFStickies.size)
        document.edit(page: index) { $0.insert(el) }
        document.commit()
        beginEditing(el.id, on: overlay)
    }

    func beginEditing(_ id: String, on overlay: PageOverlayView) {
        endEditing()
        guard let sticky = overlay.scene.element(id) else { return }
        let t = overlay.pageToView
        let scale = hypot(t.a, t.b)
        let text = overlay.scene.liveElements.first { $0.containerId == id && $0.type == .text }
        let textView = StickyTextView(frame: sticky.rect.standardized.applying(t))
        textView.string = text?.originalText ?? ""
        textView.font = NSFont.systemFont(ofSize: (text?.fontSize ?? PDFStickies.fontSize) * scale)
        textView.alignment = .center
        textView.textColor = NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1)
        textView.backgroundColor = NSColor(srgbRed: 1, green: 0xec / 255, blue: 0x99 / 255, alpha: 1)
        textView.drawsBackground = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: TextLayout.boundPadding * scale, height: TextLayout.boundPadding * scale)
        textView.onEnd = { [weak self] in self?.endEditing() }
        overlay.addSubview(textView)
        overlay.hiddenElements.formUnion(text.map { [$0.id] } ?? [])
        editing = StickyEditing(id: id, overlay: overlay, textView: textView)
        window?.makeFirstResponder(textView)
        textView.selectAll(nil)
    }

    /// 結束編輯：注音組字中的文字先確定，再寫回並重新排版
    func endEditing() {
        guard let current = editing else { return }
        editing = nil
        let textView = current.textView
        if textView.hasMarkedText() { textView.unmarkText() }
        let text = textView.string
        textView.onEnd = nil
        textView.removeFromSuperview()
        guard let overlay = current.overlay else { return }
        overlay.hiddenElements = []
        let old = overlay.scene.liveElements.first { $0.containerId == current.id && $0.type == .text }?.originalText ?? ""
        guard text != old, overlay.scene.element(current.id) != nil else { return }
        document.edit(page: overlay.pageIndex) { $0.setStickyText(current.id, to: text) }
        document.commit()
    }
}

/// 便利貼的文字框：Esc 或失去焦點就結束編輯（組字中的 Esc 交給輸入法）
final class StickyTextView: NSTextView {
    var onEnd: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender); return }
        onEnd?()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.onEnd?() } }
        return resigned
    }
}
#endif
