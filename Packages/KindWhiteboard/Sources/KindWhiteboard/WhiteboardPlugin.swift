import EasyNotesUI
import SwiftUI

/// .excalidraw：PencilKit 手寫層。結構元素層在 Phase 4 加入。
public enum WhiteboardPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        registry.addKind(InkKind.self, name: "白板", symbol: "pencil.tip", tint: .violet)
        registry.addPreview(for: InkKind.id, BoardPreview())
        registry.addController(WhiteboardController.shared)
        registry.addEditor(for: InkKind.id) { InkEditorView(path: $0).id($0) }
        registry.addNewFile("新手寫", kind: InkKind.self, symbol: "pencil.tip",
                            shortcut: KeyboardShortcut("n", modifiers: [.command, .shift]), defaultName: "手寫")
        #if os(iOS)
        // Spike S3：DEBUG 或啟動參數 `-WhiteboardSpike YES`（Release 實機量測用）
        if _isDebugAssertConfiguration() || UserDefaults.standard.bool(forKey: "WhiteboardSpike") {
            registry.addPanel(id: "whiteboard-spike", title: "畫布 Spike", symbol: "scribble.variable") {
                CanvasSpikeView()
            }
        }
        #endif
    }
}

/// 白板縮圖：Phase 4 前先用設計稿的佔位樣式（Thumb Board）
struct BoardPreview: DocumentPreviewProvider {
    func makePreview(_ data: Data) -> DocumentPreview { DocumentPreview() }

    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView {
        AnyView(ThumbBoard(tint: .violet, scale: scale))
    }
}
