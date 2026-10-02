import EasyNotesUI
import SwiftUI

/// .md：CodeMirror 6 編輯器（WebView）。和其他外掛走同一套介面，沒有特權通道。
public enum MarkdownPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        let editor = MarkdownEditor.shared // 啟動時就預先載入 WebView，打開第一篇筆記時不會卡頓
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
        ])
    }

    /// Vault 根目錄 `CLAUDE.md` 的筆記慣例一節（l10n:fixed：給 Claude Code 讀，內容語言固定）
    static let guide = """
        ## 筆記（Markdown）

        - 第一個 `# 標題` 是筆記標題；沒有時用檔名。
        - `[[筆記名稱]]` 連到其他筆記（不含副檔名，別名寫成 `[[名稱|顯示文字]]`）；找不到的名稱，點擊時會建立新筆記。
        - `[[連結]]` 獨占一行時顯示為連結卡片；`![[附件/圖.png]]` 嵌入圖片。
        - 標籤：內文 `#標籤`（階層用 `#上層/下層`）或 frontmatter `tags: [a, b]`。
        - frontmatter 欄位：`pinned: true`（釘選）、`icon: 🗺` 或 `icon: sf:map`（SF Symbol）、`cover: 附件/封面.jpg`、`tags`。其他欄位原樣保留。
        - 圖片等附件放在 Vault 根目錄的 `附件/`。
        - callout：`> [!tip] 文字`；待辦：`- [ ] 項目`。
        """
}
