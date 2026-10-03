import EasyNotesUI
import SwiftUI

/// .csv、.tsv：RevoGrid 編輯器（見 architecture/sheets.md）
public enum SheetPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        registry.addKind(CSVKind.self, name: L("表格"), symbol: "tablecells", tint: .green)
        registry.addKind(TSVKind.self, name: "TSV", symbol: "tablecells", tint: .green)
        registry.addCompanionKind(CSVMetaKind.self)
        registry.addCompanionKind(TSVMetaKind.self)
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
}
