#if os(iOS)
import ExcalidrawKit
import UIKit

/// iPad / iPhone 便利貼（見 architecture/pdf.md「便利貼」「頁面疊層」）：
/// - 非手寫模式：Pencil 與手指點一下選取（外框、縮放點與「編輯 / 刪除」選單），再點一下編輯；拖曳移動、拖曳縮放點縮放。
/// - 手寫模式：Pencil 書寫（可寫在便利貼上），手指點一下選取 / 編輯、長按才拖曳。
extension PageOverlayView: UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    private enum Gesture {
        static let tap = "stickyTap"
        static let pan = "stickyPan"
        static let longPress = "stickyLongPress"
    }

    func setUpStickyGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStickyTap(_:)))
        tap.name = Gesture.tap
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleStickyDrag(_:)))
        pan.name = Gesture.pan
        pan.maximumNumberOfTouches = 1
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleStickyDrag(_:)))
        longPress.name = Gesture.longPress
        longPress.minimumPressDuration = 0.35
        longPress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        for g in [tap, pan, longPress] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        addInteraction(UIEditMenuInteraction(delegate: self))
        applyInking(false)
    }

    private func gesture(_ name: String) -> UIGestureRecognizer? {
        gestureRecognizers?.first { $0.name == name }
    }

    /// 手寫模式：Pencil 是筆，只有手指點選；拖曳改成長按
    func applyInking(_ inking: Bool) {
        gesture(Gesture.pan)?.isEnabled = !inking
        gesture(Gesture.longPress)?.isEnabled = inking
        gesture(Gesture.tap)?.allowedTouchTypes = (inking ? [.direct] : [UITouch.TouchType.direct, .pencil])
            .map { $0.rawValue as NSNumber }
    }

    // MARK: 手勢

    /// 拖曳手勢在移動一段距離後才開始：起點 = 目前位置 − 位移
    private func startPoint(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: self)
        guard let pan = g as? UIPanGestureRecognizer else { return p }
        let t = pan.translation(in: self)
        return CGPoint(x: p.x - t.x, y: p.y - t.y)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard [Gesture.tap, Gesture.pan, Gesture.longPress].contains(g.name ?? "") else {
            return super.gestureRecognizerShouldBegin(g)
        }
        // 只在便利貼上；編輯中的文字框自己處理觸控
        let p = startPoint(g)
        if let textView = host?.editing?.textView, textView.frame.contains(p) { return false }
        return sticky(at: p) != nil
    }

    /// PDFView 的捲動與文字選取等便利貼的點選、拖曳先失敗（縮放不等、長按不擋捲動）
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard g.name == Gesture.tap || g.name == Gesture.pan, let view = other.view, view !== self,
              isDescendant(of: view), !(other is UIPinchGestureRecognizer) else { return false }
        return true
    }

    @objc private func handleStickyTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let host, let el = sticky(at: g.location(in: self)) else { return }
        if selectedSticky == el.id {
            host.beginEditing(el.id, on: self)
        } else {
            host.endEditing()
            select(el.id)
        }
    }

    @objc private func handleStickyDrag(_ g: UIGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            guard let el = sticky(at: startPoint(g)) else { return }
            host?.endEditing()
            dismissEditMenu()
            select(el.id, showsMenu: false)
            startDrag(el, at: startPoint(g))
            continueDrag(to: p)
        case .changed:
            continueDrag(to: p)
        case .ended:
            endDrag(at: p)
        case .cancelled, .failed:
            endDrag(at: p, cancel: true)
        default:
            break
        }
    }

    // MARK: 選取

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
        dismissEditMenu()
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

    private func dismissEditMenu() {
        editMenu?.dismissMenu()
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

// MARK: - 畫布：取消選取與文字編輯

extension PDFReaderCanvas: UIGestureRecognizerDelegate, UITextViewDelegate {
    func setUpStickies() {
        // 點便利貼以外的地方：結束編輯、取消選取（不攔截，PDFView 照常處理）
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func handleBackgroundTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let p = g.location(in: self)
        if let textView = editing?.textView, textView.bounds.contains(textView.convert(p, from: self)) { return }
        // 點在便利貼上：交給 overlay（選取或編輯）
        if overlays.values.contains(where: { $0.sticky(at: $0.convert(p, from: self)) != nil }) { return }
        endEditing()
        for overlay in overlays.values where overlay.selectedSticky != nil { overlay.deselect() }
    }

    /// 同時只有一張選取
    func stickySelected(on overlay: PageOverlayView) {
        for other in overlays.values where other !== overlay && other.selectedSticky != nil { other.deselect() }
    }

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
        textView.backgroundColor = UIColor(cgColor: PDFStickies.fill)
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
        overlay.hiddenElements.formUnion(text.map { [$0.id] } ?? [])
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
        textView.resignFirstResponder()
        textView.removeFromSuperview()
        updateToolPicker() // 工具盤與 ⌘Z 回到畫布
        guard let overlay = current.overlay else { return }
        overlay.hiddenElements = []
        let old = overlay.scene.liveElements.first { $0.containerId == current.id && $0.type == .text }?.originalText ?? ""
        guard text != old, overlay.scene.element(current.id) != nil else { return }
        editStickies(page: overlay.pageIndex) { $0.setStickyText(current.id, to: text) }
    }

    /// 例如按了鍵盤的收合鍵
    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === editing?.textView { endEditing() }
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
