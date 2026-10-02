import EasyNotesUI
import PencilKit
import SwiftUI

/// 白板編輯器。iOS：`BoardCanvasView`（結構層 + PencilKit 手寫，筆畫存成 Excalidraw freedraw）；
/// macOS：`BoardMacCanvasView`（同一個結構層加滑鼠 / 觸控板互動，手寫只能看）。
struct BoardEditorView: View {
    let path: String
    @Environment(\.documentSession) private var session
    @State private var document: BoardDocument?
    @State private var editor: BoardEditor?
    /// 畫布背景是 App 偏好設定，不寫進檔案（Excalidraw 沒有對應欄位）
    @AppStorage("whiteboardBackground") private var background = BoardBackground.dots
    @AppStorage("whiteboardSelectionShape") private var selectionShape = SelectionShape.rectangle

    var body: some View {
        // 不能用 Group：Group 的修飾器套在每個子 view 上，document 還是 nil 時沒有子 view，onAppear 永遠不會被呼叫
        ZStack {
            if let document, let editor {
                #if os(iOS)
                BoardCanvas(document: document, editor: editor, background: background, selectionShape: selectionShape)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottomTrailing) {
                        BoardBackgroundMenu(background: $background).padding(16)
                    }
                    // 工具列獨立一排，在導覽列（檔名、設定）下方
                    .safeAreaInset(edge: .top, spacing: 0) { BoardToolbar(editor: editor, selectionShape: $selectionShape) }
                #else
                BoardMacCanvas(document: document, editor: editor, background: background, selectionShape: selectionShape)
                    .overlay(alignment: .bottomTrailing) {
                        BoardBackgroundMenu(background: $background).padding(16)
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        BoardToolbar(editor: editor, selectionShape: $selectionShape, showsInk: false)
                    }
                #endif
            }
        }
        .onAppear {
            if document == nil, let session {
                let doc = WhiteboardController.shared.open(path, session: session)
                document = doc
                editor = BoardEditor(document: doc)
            }
        }
        .onDisappear { WhiteboardController.shared.close(path: path) }
    }
}

#if os(iOS)
private struct BoardCanvas: UIViewRepresentable {
    let document: BoardDocument
    let editor: BoardEditor
    let background: BoardBackground
    let selectionShape: SelectionShape

    func makeUIView(context: Context) -> BoardCanvasView {
        let view = BoardCanvasView(document: document, editor: editor)
        updateUIView(view, context: context)
        return view
    }

    /// 讀 `editor.inking`：工具列切換時 SwiftUI 會再呼叫這裡
    func updateUIView(_ view: BoardCanvasView, context: Context) {
        view.apply(inking: editor.inking)
        view.apply(background: background)
        editor.selectionShape = selectionShape
    }

    static func dismantleUIView(_ view: BoardCanvasView, coordinator: ()) {
        view.finishText()
        view.saveNow()
    }
}
#else
private struct BoardMacCanvas: NSViewRepresentable {
    let document: BoardDocument
    let editor: BoardEditor
    let background: BoardBackground
    let selectionShape: SelectionShape

    func makeNSView(context: Context) -> BoardMacCanvasView {
        let view = BoardMacCanvasView(document: document, editor: editor)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BoardMacCanvasView, context: Context) {
        view.apply(background: background)
        editor.selectionShape = selectionShape
    }

    static func dismantleNSView(_ view: BoardMacCanvasView, coordinator: ()) {
        view.close()
    }
}
#endif
