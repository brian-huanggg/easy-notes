import EasyNotesUI
import ExcalidrawKit
import SwiftUI

/// .excalidraw：白板（結構元素 + PencilKit 手寫，見 architecture/whiteboard.md）
public enum WhiteboardPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        registry.addKind(InkKind.self, name: L("白板"), symbol: "pencil.tip", tint: .violet)
        registry.addPreview(for: InkKind.id, BoardPreview())
        registry.addController(WhiteboardController.shared)
        registry.addEditor(for: InkKind.id) { BoardEditorView(path: $0).id($0) }
        registry.addNewFile(L("新白板"), kind: InkKind.self, symbol: "pencil.tip",
                            shortcut: KeyboardShortcut("n", modifiers: [.command, .shift]), defaultName: L("白板"))
    }
}
