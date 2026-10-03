#if os(macOS)
import AppKit
import ExcalidrawKit

/// macOS 便利貼：滑過顯示外框、拖曳移動 / 縮放、雙擊或右鍵編輯、右鍵刪除（見 architecture/pdf.md「macOS 便利貼」）
extension PageOverlayView {
    func stickyMouseMoved(_ event: NSEvent) {
        guard drag == nil, host?.editing?.overlay !== self else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let el = sticky(at: p) else { hideChrome(); return }
        showChrome(for: el)
        (handleRect(for: el).contains(p) ? NSCursor.frameResize(position: .bottomRight, directions: .all) : .openHand).set()
    }

    func stickyMouseDown(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let el = sticky(at: p) else { return }
        host?.endEditing()
        if event.clickCount >= 2 {
            hideChrome()
            host?.beginEditing(el.id, on: self)
        } else {
            startDrag(el, at: p)
        }
    }

    func stickyMouseDragged(_ event: NSEvent) {
        guard let drag else { return }
        continueDrag(to: convert(event.locationInWindow, from: nil))
        (drag.mode == .move ? NSCursor.closedHand : NSCursor.frameResize(position: .bottomRight, directions: .all)).set()
    }

    func stickyMouseUp(_ event: NSEvent) {
        endDrag(at: convert(event.locationInWindow, from: nil))
    }

    func stickyMenu(_ event: NSEvent) -> NSMenu? {
        guard let el = sticky(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let menu = NSMenu()
        menu.addItem(StickyMenuItem(L("編輯")) { [weak self] in
            guard let self else { return }
            host?.beginEditing(el.id, on: self)
        })
        menu.addItem(StickyMenuItem(L("刪除")) { [weak self] in
            guard let self else { return }
            host?.deleteSticky(el.id, on: self)
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

// MARK: - 文字編輯

extension PDFReaderCanvas {
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
        textView.textColor = NSColor(cgColor: PDFStickies.ink)
        textView.backgroundColor = NSColor(cgColor: PDFStickies.fill) ?? .yellow
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
        editStickies(page: overlay.pageIndex) { $0.setStickyText(current.id, to: text) }
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
