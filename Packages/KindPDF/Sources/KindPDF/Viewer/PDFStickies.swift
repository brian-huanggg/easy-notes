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

/// 拖曳中的便利貼：標註層隱藏它，`preview`（只畫它的標註層）跟著游標，放開才寫入
struct StickyDrag {
    let id: String
    let start: CGPoint
    var preview: PageInkLayer?
}

// MARK: - overlay：點選、拖曳、右鍵選單

extension PageOverlayView {
    /// 最上層、包含這個點的便利貼（overlay 座標）
    func sticky(at viewPoint: CGPoint) -> Element? {
        let p = pagePoint(viewPoint)
        return scene.liveElements.reversed().first { $0.type == .rectangle && $0.rect.standardized.contains(p) }
    }

    func stickyMouseDown(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let el = sticky(at: p) else { return }
        host?.endEditing()
        if event.clickCount >= 2 {
            host?.beginEditing(el.id, on: self)
        } else {
            drag = StickyDrag(id: el.id, start: p)
        }
    }

    func stickyMouseDragged(_ event: NSEvent) {
        guard var drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if drag.preview == nil {
            let ids = scene.stickyIDs(drag.id)
            let preview = PageInkLayer()
            preview.contentsScale = inkLayer.contentsScale
            preview.frame = inkLayer.frame
            preview.setPageTransform(pageToView)
            preview.show(scene.only(ids))
            layer?.addSublayer(preview)
            hiddenElements.formUnion(ids)
            drag.preview = preview
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drag.preview?.setAffineTransform(CGAffineTransform(translationX: p.x - drag.start.x, y: p.y - drag.start.y))
        CATransaction.commit()
        self.drag = drag
        NSCursor.closedHand.set()
    }

    func stickyMouseUp(_ event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        guard let preview = drag.preview else { return }
        let a = pagePoint(drag.start), b = pagePoint(convert(event.locationInWindow, from: nil))
        hiddenElements.subtract(scene.stickyIDs(drag.id))
        if let document = host?.document, a != b {
            document.edit(page: pageIndex) { $0.move([drag.id], dx: b.x - a.x, dy: b.y - a.y) }
            document.commit()
        }
        // 標註層在背景重畫完之前先留著預覽，避免便利貼閃一下
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { preview.removeFromSuperlayer() }
        NSCursor.arrow.set()
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
