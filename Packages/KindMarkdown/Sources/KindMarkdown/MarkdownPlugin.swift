import EasyNotesUI
import SwiftUI

/// .md：CodeMirror 6 編輯器（WebView）。和其他外掛走同一套介面，沒有特權通道。
public enum MarkdownPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        let editor = MarkdownEditor.shared // 啟動時就預先載入 WebView，打開第一篇筆記時不會卡頓
        registry.addKind(MarkdownKind.self, symbol: "doc.text", tint: .neutral)
        registry.addEditor(for: MarkdownKind.id) { MarkdownEditorView(path: $0) }
        registry.addNewFile("新筆記", kind: MarkdownKind.self, symbol: "square.and.pencil",
                            shortcut: KeyboardShortcut("n"), defaultName: "未命名")
        registry.addController(editor)
        // ⌘B / ⌘I 由 CodeMirror keymap 處理，這裡只提供選單入口
        registry.addMenu("格式", sections: [
            [
                .init("標題") { editor.exec("heading") },
                .init("粗體") { editor.exec("bold") },
                .init("斜體") { editor.exec("italic") },
                .init("行內程式碼") { editor.exec("code") },
            ],
            [
                .init("項目清單") { editor.exec("bullet") },
                .init("待辦事項", shortcut: KeyboardShortcut("l", modifiers: [.command, .shift])) { editor.exec("task") },
                .init("[[連結]]", shortcut: KeyboardShortcut("k")) { editor.exec("link") },
            ],
        ])
    }
}
