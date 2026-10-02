import EasyNotesUI
import PencilKit
import SwiftUI

/// 白板編輯器。iOS：`BoardCanvasView`（結構層 + PencilKit 手寫，筆畫存成 Excalidraw freedraw）；
/// macOS：目前只能檢視手寫（4c 之後改成同一個結構層加滑鼠互動）。
struct BoardEditorView: View {
    let path: String
    @Environment(\.documentSession) private var session
    @State private var document: BoardDocument?

    var body: some View {
        Group {
            if let document {
                #if os(iOS)
                BoardCanvas(document: document)
                    .ignoresSafeArea(edges: .bottom)
                #else
                InkPreview(scene: document.scene)
                #endif
            }
        }
        .onAppear {
            if document == nil, let session { document = WhiteboardController.shared.open(path, session: session) }
        }
        .onDisappear { WhiteboardController.shared.close(path: path) }
    }
}

#if os(iOS)
private struct BoardCanvas: UIViewRepresentable {
    let document: BoardDocument

    func makeUIView(context: Context) -> BoardCanvasView {
        BoardCanvasView(document: document)
    }

    func updateUIView(_ view: BoardCanvasView, context: Context) {}

    static func dismantleUIView(_ view: BoardCanvasView, coordinator: ()) {
        view.saveNow()
    }
}
#else
private struct InkPreview: View {
    let scene: ExcalidrawScene

    var body: some View {
        let drawing = scene.drawing
        VStack(spacing: 12) {
            if drawing.strokes.isEmpty {
                ContentUnavailableView("尚無筆畫", systemImage: "pencil.tip",
                                       description: Text("手寫編輯需在 iPad / iPhone 上進行，Mac 目前只能檢視。"))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: drawing.image(from: drawing.bounds.insetBy(dx: -24, dy: -24), scale: 2))
                        .padding()
                }
                Text("手寫編輯需在 iPad / iPhone 上進行，Mac 目前只能檢視。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
#endif
