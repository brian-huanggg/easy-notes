import EasyNotesUI
import SwiftUI

/// .md：CodeMirror 6 編輯器（WebView）。和其他外掛走同一套介面，沒有特權通道。
public enum MarkdownPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        let editor = MarkdownEditor.shared // The WebView is pre-warmed in `launched()`, after the window appears
        registry.addKind(MarkdownKind.self, name: L("筆記"), symbol: "doc.text", tint: .neutral)
        registry.addPreview(for: MarkdownKind.id, MarkdownPreview())
        registry.addEditor(for: MarkdownKind.id) { MarkdownEditorView(path: $0) }
        registry.addNewFile(L("新筆記"), kind: MarkdownKind.self, symbol: "square.and.pencil",
                            shortcut: KeyboardShortcut("n"), defaultName: L("未命名"))
        registry.addController(editor)
        registry.addVaultGuide(guide)
        // ⌘B / ⌘I 由 CodeMirror keymap 處理，這裡只提供選單入口
        registry.addMenu(L("格式"), sections: [
            [
                .init(L("標題")) { editor.exec("heading") },
                .init(L("粗體")) { editor.exec("bold") },
                .init(L("斜體")) { editor.exec("italic") },
                .init(L("行內程式碼")) { editor.exec("code") },
            ],
            [
                .init(L("項目清單")) { editor.exec("bullet") },
                .init(L("待辦事項"), shortcut: KeyboardShortcut("l", modifiers: [.command, .shift])) { editor.exec("task") },
                // ⌘K 是外殼的快速開啟
                .init(L("[[連結]]"), shortcut: KeyboardShortcut("k", modifiers: [.command, .shift])) { editor.exec("link") },
            ],
            [
                // 焦點在編輯器時 CodeMirror 的 keymap 也會處理 ⌘F；選單項目讓焦點在別處時也能開啟
                .init(L("在筆記中尋找…"), shortcut: KeyboardShortcut("f")) { editor.exec("find") },
            ],
        ])
    }

    /// Vault 根目錄 `CLAUDE.md` 的筆記慣例一節（l10n:fixed：給 Claude Code 讀，內容固定用英文）
    static let guide = """
        ## Notes (Markdown)

        - The first `# Heading` is the note's title; without one the file name is used.
        - `[[Note name]]` links to another note (no extension; use `[[Name|Display text]]` for an alias). Clicking a name that does not exist creates a new note.
        - A `[[link]]` alone on a line is shown as a link card; `![[Attachments/image.png]]` embeds an image.
        - Tags: `#tag` in the body (nested as `#parent/child`) or frontmatter `tags: [a, b]`.
        - Frontmatter fields: `pinned: true`, `icon: 🗺` or `icon: sf:map` (SF Symbol), `cover: Attachments/cover.jpg`, `tags`. Other fields are preserved as-is.
        - Images and other attachments live in `Attachments/` at the vault root. Older vaults may still have `附件/`: those paths keep working, but put new files in `Attachments/`.
        - Callout: `> [!tip] text`; task: `- [ ] item`.
        """
}
