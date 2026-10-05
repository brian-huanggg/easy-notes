#if os(iOS)
import ExcalidrawKit
import UIKit

/// iPad / iPhone 便利貼（見 architecture/pdf.md「iOS 便利貼」）：
/// - 非手寫模式：Pencil 與手指點一下選取（外框、縮放點與「編輯 / 刪除」選單），再點一下編輯；拖曳移動、拖曳縮放點縮放。
/// - 手寫模式：Pencil 書寫（可寫在便利貼上），手指點一下選取 / 編輯、長按才拖曳。
/// 手勢裝在 `PDFReaderCanvas`（PDFView 之外）再換算到各頁 overlay：PDFKit 不一定把觸控交給 overlay。
extension PDFReaderCanvas: UIGestureRecognizerDelegate, UITextViewDelegate {
    private enum Gesture {
        static let tap = "stickyTap"
        static let pan = "stickyPan"
        static let longPress = "stickyLongPress"
        static let background = "stickyBackground"
    }

    func setUpStickies() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStickyTap(_:)))
        tap.name = Gesture.tap
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleStickyDrag(_:)))
        pan.name = Gesture.pan
        pan.maximumNumberOfTouches = 1
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleStickyDrag(_:)))
        longPress.name = Gesture.longPress
        longPress.minimumPressDuration = 0.35
        longPress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        // 點便利貼以外的地方：結束編輯、取消選取（不攔截，PDFView 照常處理）
        let background = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
        background.name = Gesture.background
        background.cancelsTouchesInView = false
        for g in [tap, pan, longPress, background] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        applyStickyInking()
    }

    private func gesture(_ name: String) -> UIGestureRecognizer? {
        gestureRecognizers?.first { $0.name == name }
    }

    /// 手寫模式：Pencil 是筆，只有手指點選；拖曳改成長按
    func applyStickyInking() {
        gesture(Gesture.pan)?.isEnabled = !inking
        gesture(Gesture.longPress)?.isEnabled = inking
        gesture(Gesture.tap)?.allowedTouchTypes = (inking ? [.direct] : [UITouch.TouchType.direct, .pencil])
            .map { $0.rawValue as NSNumber }
    }

    /// 點 `p`（這個 view 的座標）上最上層的便利貼與它所在的頁
    private func sticky(at p: CGPoint) -> (overlay: PageOverlayView, element: Element, point: CGPoint)? {
        for overlay in overlays.values {
            let q = overlay.convert(p, from: self)
            guard overlay.bounds.insetBy(dx: -24, dy: -24).contains(q), let el = overlay.sticky(at: q) else { continue }
            return (overlay, el, q)
        }
        return nil
    }

    private func isInTextView(_ p: CGPoint) -> Bool {
        guard let textView = editing?.textView else { return false }
        return textView.bounds.contains(textView.convert(p, from: self))
    }

    /// 拖曳手勢在移動一段距離後才開始：起點 = 目前位置 − 位移
    private func startPoint(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: self)
        guard let pan = g as? UIPanGestureRecognizer else { return p }
        let t = pan.translation(in: self)
        return CGPoint(x: p.x - t.x, y: p.y - t.y)
    }

    // MARK: 手勢分工

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        switch g.name {
        case Gesture.tap, Gesture.pan, Gesture.longPress:
            // 只在便利貼上；編輯中的文字框自己處理觸控
            let p = startPoint(g)
            return !isInTextView(p) && sticky(at: p) != nil
        case Gesture.background:
            return true
        default:
            return super.gestureRecognizerShouldBegin(g)
        }
    }

    /// 非手寫模式：PDFView 的捲動、文字選取等便利貼的點選與拖曳先失敗（縮放不等、文字框不受影響）。
    /// 手寫模式不設：PencilKit 的書寫手勢掛在畫布內部的 view 上，等便利貼的點選失敗會讓 Pencil 在便利貼上寫不出來
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard !inking, g.name == Gesture.tap || g.name == Gesture.pan, other.view !== self,
              !(other is UIPinchGestureRecognizer), let view = other.view,
              !overlays.values.contains(where: { view.isDescendant(of: $0.canvas) }),
              !(editing.map { view.isDescendant(of: $0.textView) } ?? false) else { return false }
        return view.isDescendant(of: pdfView)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g.name == Gesture.background
    }

    // MARK: 點選與拖曳

    @objc private func handleStickyTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let hit = sticky(at: g.location(in: self)) else { return }
        if hit.overlay.selectedSticky == hit.element.id {
            beginEditing(hit.element.id, on: hit.overlay)
        } else {
            endEditing()
            hit.overlay.select(hit.element.id)
        }
    }

    @objc private func handleBackgroundTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let p = g.location(in: self)
        if isInTextView(p) || sticky(at: p) != nil { return } // 便利貼上的點選由 handleStickyTap 處理
        endEditing()
        for overlay in overlays.values where overlay.selectedSticky != nil { overlay.deselect() }
    }

    @objc private func handleStickyDrag(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began:
            guard let hit = sticky(at: startPoint(g)) else { return }
            endEditing()
            hit.overlay.select(hit.element.id, showsMenu: false)
            dragOverlay = hit.overlay
            hit.overlay.startDrag(hit.element, at: hit.point)
            hit.overlay.continueDrag(to: g.location(in: hit.overlay))
        case .changed:
            guard let overlay = dragOverlay else { return }
            overlay.continueDrag(to: g.location(in: overlay))
        case .ended, .cancelled, .failed:
            guard let overlay = dragOverlay else { return }
            dragOverlay = nil
            overlay.endDrag(at: g.location(in: overlay), cancel: g.state != .ended)
        default:
            break
        }
    }

    /// 同時只有一張選取
    func stickySelected(on overlay: PageOverlayView) {
        for other in overlays.values where other !== overlay && other.selectedSticky != nil { other.deselect() }
    }

    // MARK: 文字編輯

    func beginEditing(_ id: String, on overlay: PageOverlayView) {
        endEditing()
        overlay.deselect()
        guard let sticky = overlay.scene.element(id) else { return }
        let t = overlay.pageToView
        let scale = hypot(t.a, t.b)
        let text = overlay.scene.liveElements.first { $0.containerId == id && $0.type == .text }
        let textView = StickyTextView(frame: sticky.rect.standardized.applying(t))
        textView.text = text?.originalText ?? ""
        textView.font = .systemFont(ofSize: (text?.fontSize ?? PDFStickies.fontSize) * scale)
        textView.textAlignment = .center
        textView.textColor = UIColor(cgColor: PDFStickies.ink)
        // 不透明、蓋住整張便利貼：標註層不必隱藏它的文字（不重畫分塊，不會露出底下的 PDF）
        textView.backgroundColor = UIColor(cgColor: PDFStickies.fill)
        textView.isOpaque = true
        let pad = TextLayout.boundPadding * scale
        textView.textContainerInset = UIEdgeInsets(top: pad, left: pad, bottom: pad, right: pad)
        textView.textContainer.lineFragmentPadding = 0
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.delegate = self
        textView.onEscape = { [weak self] in self?.endEditing() }
        // 文字框在 PDFView 的縮放 transform 裡：點陣倍率與畫布相同才清晰
        textView.setRaster(overlay.canvas.contentScaleFactor)
        overlay.addSubview(textView) // 編輯時在手寫之上
        editing = StickyEditing(id: id, overlay: overlay, textView: textView)
        textView.becomeFirstResponder()
    }

    /// 結束編輯：注音組字中的文字先確定，再寫回並重新排版
    func endEditing() {
        guard let current = editing else { return }
        editing = nil
        let textView = current.textView
        textView.unmarkText()
        let text = textView.text ?? ""
        textView.delegate = nil
        textView.onEscape = nil
        textView.isUserInteractionEnabled = false
        textView.resignFirstResponder()
        reclaimFirstResponder() // ⌘Z 回到畫布
        if let overlay = current.overlay {
            let old = overlay.scene.liveElements.first { $0.containerId == current.id && $0.type == .text }?.originalText ?? ""
            if text != old, overlay.scene.element(current.id) != nil {
                editStickies(page: overlay.pageIndex) { $0.setStickyText(current.id, to: text) }
            }
        }
        // 標註層在背景重畫完新文字之前先留著文字框，避免露出底下的 PDF
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { textView.removeFromSuperview() }
    }

    /// 例如按了鍵盤的收合鍵
    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === editing?.textView { endEditing() }
    }
}

// MARK: - overlay：選取與選單

extension PageOverlayView: @preconcurrency UIEditMenuInteractionDelegate {
    func select(_ id: String, showsMenu: Bool = true) {
        host?.stickySelected(on: self)
        selectedSticky = id
        refreshSelection()
        guard showsMenu, let el = scene.element(id) else { return }
        let r = el.rect.standardized.applying(pageToView)
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: r.midX, y: r.minY)))
    }

    func deselect() {
        selectedSticky = nil
        editMenu?.dismissMenu()
        refreshSelection()
    }

    /// 外框跟著選取的便利貼（被刪除、外部合併移除時取消選取）；拖曳中由拖曳負責
    func refreshSelection() {
        guard drag == nil else { return }
        if let id = selectedSticky, let el = scene.element(id), !el.isDeleted {
            showChrome(for: el)
        } else {
            selectedSticky = nil
            hideChrome()
        }
    }

    private var editMenu: UIEditMenuInteraction? {
        interactions.first { $0 is UIEditMenuInteraction } as? UIEditMenuInteraction
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let id = selectedSticky else { return nil }
        return UIMenu(children: [
            UIAction(title: L("編輯"), image: UIImage(systemName: "pencil")) { [weak self] _ in
                guard let self else { return }
                host?.beginEditing(id, on: self)
            },
            UIAction(title: L("刪除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                deselect()
                host?.deleteSticky(id, on: self)
            },
        ])
    }
}

/// 便利貼的文字框：外接鍵盤的 Esc 結束編輯（組字中的 Esc 交給輸入法）
final class StickyTextView: UITextView {
    var onEscape: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil else { return [] }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func escape() { onEscape?() }

    func setRaster(_ scale: CGFloat) {
        func apply(_ view: UIView) {
            view.contentScaleFactor = scale
            view.subviews.forEach(apply)
        }
        apply(self)
    }
}
#endif
