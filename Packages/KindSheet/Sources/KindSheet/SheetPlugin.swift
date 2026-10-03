import EasyNotesUI
import SwiftUI

/// .csv、.tsv：RevoGrid 編輯器（見 architecture/sheets.md）
public enum SheetPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        registry.addKind(CSVKind.self, name: L("表格"), symbol: "tablecells", tint: .green)
        registry.addKind(TSVKind.self, name: "TSV", symbol: "tablecells", tint: .green)
        registry.addCompanionKind(CSVMetaKind.self)
        registry.addCompanionKind(TSVMetaKind.self)
        registry.addPreview(for: CSVKind.id, SheetPreview(delimiter: CSVKind.delimiter))
        registry.addPreview(for: TSVKind.id, SheetPreview(delimiter: TSVKind.delimiter))
        registry.addNewFile(L("新表格"), kind: CSVKind.self, symbol: "tablecells", defaultName: L("表格"))
        registry.addImport(L("匯入 CSV…"), kind: CSVKind.self, symbol: "tablecells")
        registry.addVaultGuide(guide)
        registry.addController(SheetController.shared)
        registry.addEditor(for: CSVKind.id) { SheetEditorView(path: $0, kind: CSVKind.self).id($0) }
        registry.addEditor(for: TSVKind.id) { SheetEditorView(path: $0, kind: TSVKind.self).id($0) }
        // 復原 / 重做（⌘Z / ⌘⇧Z）由 JS 端處理，不放進選單，避免與系統的「編輯」選單重複
        let sheet = SheetController.shared
        registry.addMenu(L("表格"), sections: [
            [
                .init(L("在上方插入列")) { sheet.exec("insertRowAbove") },
                .init(L("在下方插入列")) { sheet.exec("insertRowBelow") },
                .init(L("刪除列")) { sheet.exec("deleteRows") },
            ],
            [
                .init(L("在左側插入欄")) { sheet.exec("insertColumnLeft") },
                .init(L("在右側插入欄")) { sheet.exec("insertColumnRight") },
                .init(L("刪除欄")) { sheet.exec("deleteColumn") },
            ],
            [
                .init(L("依此欄遞增排序並寫入")) { sheet.exec("sortAscending") },
                .init(L("依此欄遞減排序並寫入")) { sheet.exec("sortDescending") },
                .init(L("凍結首欄")) { sheet.exec("toggleFreeze") },
                .init(L("第一列是標題")) { sheet.exec("toggleHeaderRow") },
            ],
        ])
    }

    /// Vault 根目錄 `CLAUDE.md` 的表格慣例一節（l10n:fixed：給 Claude Code 讀，內容固定用英文）
    static let guide = """
        ## Tables (CSV / TSV)

        - `.csv` (comma) and `.tsv` (tab) files are plain RFC 4180 tables: UTF-8, the first row is the header.
        - Quote a field with `"` when it contains the delimiter, a quote (written as `""`) or a line break.
        - Keep the file's existing style (line endings, quoting, BOM) and edit only the rows you need: unchanged rows stay byte-for-byte identical, so edits on different rows from different devices merge automatically.
        - `[[Note name]]` inside a cell is a link; `![[Table.csv]]` in a note embeds a preview of the table.
        - No formulas, multiple sheets or charts: a cell is only text.
        - Do not modify `<file>.csv.meta.json` (column widths, frozen columns, header row); it follows the table when renamed, moved or deleted.
        - Big5-encoded files open read-only until converted to UTF-8 in the app.
        """
}
