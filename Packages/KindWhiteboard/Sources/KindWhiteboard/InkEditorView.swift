import EasyNotesUI
import PencilKit
import SwiftUI

/// 手寫：PencilKit 輸入，存成 Excalidraw freedraw（見 ExcalidrawInk）。
/// 非 freedraw 元素（例如在 excalidraw.com 加的圖形）會原封不動保留。
struct InkEditorView: View {
    let path: String
    @Environment(\.documentSession) private var session
    @State private var document: BoardDocument?

    var body: some View {
        Group {
            if let document {
                #if os(iOS)
                InkCanvas(document: document)
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
private struct InkCanvas: UIViewRepresentable {
    let document: BoardDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = document.scene.drawing
        canvas.delegate = context.coordinator
        context.coordinator.canvas = canvas
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput // 模擬器沒有 Pencil
        #else
        canvas.drawingPolicy = .default // 跟隨系統「僅使用 Apple Pencil 繪圖」設定
        #endif
        canvas.backgroundColor = .systemBackground
        canvas.contentSize = CGSize(width: 2400, height: 3200)
        canvas.minimumZoomScale = 0.5
        canvas.maximumZoomScale = 4
        canvas.alwaysBounceVertical = true

        let picker = context.coordinator.toolPicker
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.saveNow(canvas.drawing)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let document: BoardDocument
        let toolPicker = PKToolPicker()
        weak var canvas: PKCanvasView?
        private var saveTask: Task<Void, Never>?

        init(document: BoardDocument) {
            self.document = document
            super.init()
            // 外部寫入併進場景後，把新內容畫到畫布上；存檔時筆畫與場景比對，沒變的元素不會被改動
            document.onExternalChange = { [weak self] in
                guard let self, let canvas else { return }
                canvas.drawing = document.scene.drawing
            }
            document.flushHandler = { [weak self] in
                guard let self, let canvas else { return }
                saveNow(canvas.drawing)
            }
        }

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            let drawing = canvas.drawing
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                saveNow(drawing)
            }
        }

        func saveNow(_ drawing: PKDrawing) {
            saveTask?.cancel()
            document.commit { $0.update(from: drawing) }
        }
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
