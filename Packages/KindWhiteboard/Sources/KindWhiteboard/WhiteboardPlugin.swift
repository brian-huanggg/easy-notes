import EasyNotesUI
import SwiftUI

/// .excalidraw：PencilKit 手寫層。結構元素層在 Phase 4 加入。
public enum WhiteboardPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        registry.addKind(InkKind.self, symbol: "pencil.tip")
        registry.addEditor(for: InkKind.id) { InkEditorView(path: $0).id($0) }
        registry.addNewFile("新手寫", kind: InkKind.self, symbol: "pencil.tip",
                            shortcut: KeyboardShortcut("n", modifiers: [.command, .shift]), defaultName: "手寫")
    }
}
