#if os(iOS)
import EasyNotesUI
import SwiftUI

/// iPad / iPhone 的 PDF 工具列（與白板相同的 GoodNotes 式版面，見 architecture/ui.md「手寫工具列」）：
/// 選取 | 畫筆、螢光筆、橡皮擦、套索 | 便利貼；右側是匯出。Undo / Redo 與手寫選項在下方的浮動列（`PDFFloatingRow`）
struct PDFToolbar: View {
    @Binding var inking: Bool
    let handle: PDFCanvasHandle
    let export: () -> Void

    var body: some View {
        EditorToolbar {
            // 非手寫模式：點選、拖曳便利貼，捲動與選取文字
            ToolbarIconButton(L("選取"), systemImage: "hand.point.up.left", active: !inking) { inking = false }
            InkToolButtons(inking: $inking)
            ToolbarSeparator()
            ToolbarIconButton(L("便利貼"), systemImage: "note.text") { handle.canvas?.addSticky() }
        } actions: {
            ToolbarIconButton(L("匯出"), systemImage: "square.and.arrow.up", action: export)
        }
    }
}

/// 工具列下方的浮動列：左邊 Undo / Redo（模型 Undo），中間是手寫選項膠囊
struct PDFFloatingRow: View {
    let inking: Bool
    let handle: PDFCanvasHandle

    var body: some View {
        EditorFloatingRow(inking: inking, undo: UndoRedoPill(manager: { handle.canvas?.modelUndo },
                                                             undo: { handle.canvas?.undo() },
                                                             redo: { handle.canvas?.redo() }))
    }
}
#endif
