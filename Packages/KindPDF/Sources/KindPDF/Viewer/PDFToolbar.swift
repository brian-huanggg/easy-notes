#if os(iOS)
import SwiftUI

/// iPad / iPhone 的 PDF 工具列（與白板工具列相同的樣式）：畫筆（手寫模式）| Undo / Redo。導覽列下方獨立一排
struct PDFToolbar: View {
    @Binding var inking: Bool
    let handle: PDFCanvasHandle

    @State private var canUndo = false
    @State private var canRedo = false

    var body: some View {
        HStack(spacing: 6) {
            button(inking ? L("結束手寫") : L("畫筆"), inking ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                   active: inking) { inking.toggle() }
            separator
            button(L("復原"), "arrow.uturn.backward") { handle.canvas?.modelUndo.undo(); refreshUndo() }
                .disabled(!canUndo)
            button(L("重做"), "arrow.uturn.forward") { handle.canvas?.modelUndo.redo(); refreshUndo() }
                .disabled(!canRedo)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear(perform: refreshUndo)
        // 不能聽 NSUndoManagerCheckpoint：canUndo / canRedo 本身會發出它，形成無限迴圈
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in refreshUndo() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in refreshUndo() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in refreshUndo() }
    }

    private func refreshUndo() {
        canUndo = handle.canvas?.modelUndo.canUndo ?? false
        canRedo = handle.canvas?.modelUndo.canRedo ?? false
    }

    private var separator: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }

    private func button(_ title: String, _ image: String, active: Bool = false,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: image)
                .frame(width: 34, height: 34)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(title)
        .accessibilityLabel(title)
    }
}
#endif
