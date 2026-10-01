import EasyNotesCore
import PencilKit
import SwiftUI

/// 手寫：PencilKit 輸入，存成 Excalidraw freedraw（見 EasyNotesCore/Ink）。
/// 非 freedraw 元素（例如在 excalidraw.com 加的圖形）會原封不動保留。
struct InkEditorView: View {
    let path: String
    @Environment(VaultStore.self) private var store

    var body: some View {
        #if os(iOS)
        InkCanvas(path: path, store: store)
            .ignoresSafeArea(edges: .bottom)
        #else
        InkPreview(scene: (try? ExcalidrawScene(data: store.readData(path))) ?? ExcalidrawScene())
        #endif
    }
}

#if os(iOS)
private struct InkCanvas: UIViewRepresentable {
    let path: String
    let store: VaultStore

    func makeCoordinator() -> Coordinator {
        Coordinator(path: path, store: store)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = context.coordinator.scene.drawing
        canvas.delegate = context.coordinator
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
        let path: String
        let store: VaultStore
        let toolPicker = PKToolPicker()
        var scene: ExcalidrawScene
        private var saveTask: Task<Void, Never>?

        init(path: String, store: VaultStore) {
            self.path = path
            self.store = store
            scene = (try? ExcalidrawScene(data: store.readData(path))) ?? ExcalidrawScene()
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
            let before = try? scene.data()
            scene.update(from: drawing)
            guard let data = try? scene.data(), data != before else { return }
            store.write(data, to: path)
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
