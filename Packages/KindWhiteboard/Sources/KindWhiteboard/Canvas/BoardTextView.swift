#if os(iOS)
import UIKit

/// 白板文字的原生編輯框（注音組字、Scribble 都是系統的）。打字的 Undo 用自己的 undoManager，
/// 不混進白板（`PKCanvasView`）的堆疊；整次編輯結束後由 `BoardEditor` 記一筆。
final class BoardTextView: UITextView {
    var onEscape: (() -> Void)?
    private let typingUndo = UndoManager()

    override var undoManager: UndoManager? { typingUndo }

    /// 組字中的 Esc 交給輸入法（取消組字），不結束編輯
    override var keyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil else { return super.keyCommands }
        return (super.keyCommands ?? []) + [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                                                         action: #selector(escape))]
    }

    @objc private func escape() { onEscape?() }
}
#endif

#if os(macOS)
import AppKit

/// 白板文字的原生編輯框（注音組字是系統的）。打字的 Undo 用自己的 undoManager，
/// 不混進白板的堆疊；整次編輯結束後由 `BoardEditor` 記一筆。
final class BoardTextView: NSTextView {
    var onEscape: (() -> Void)?
    private let typingUndo = UndoManager()

    override var undoManager: UndoManager? { typingUndo }

    /// 沒有組字時的 Esc 才會走到這裡（組字中由輸入法取消組字）
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// 白板文字是純文字：貼上不帶格式
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}
#endif
