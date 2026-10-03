import EasyNotesCore
import Foundation
import Testing
@testable import KindSheet

/// 顯示設定旁檔 `.csv.meta.json`：格式、增刪欄、三方合併與伴隨檔註冊
struct SheetMetaTests {
    @Test func roundTripsAndNormalizes() throws {
        let meta = SheetMeta(columns: [.init(width: 90), .init(), .init()], frozenColumns: 1, headerRow: false)
        #expect(meta.columns == [.init(width: 90)])
        #expect(try SheetMeta(data: meta.data()) == meta)
        #expect(!meta.isDefault)
        #expect(SheetMeta().isDefault)
        #expect(SheetMeta(columns: [.init(), .init()]).isDefault)
    }

    @Test func missingFieldsUseDefaults() throws {
        let meta = try SheetMeta(data: Data(#"{"columns":[{},{"width":120}]}"#.utf8))
        #expect(meta == SheetMeta(columns: [.init(), .init(width: 120)], frozenColumns: 0, headerRow: true))
        #expect(throws: (any Error).self) { try SheetMeta(data: Data("不是 JSON".utf8)) }
    }

    @Test func columnEditsShiftWidthsAndFrozenColumns() {
        var meta = SheetMeta(columns: [.init(width: 90), .init(width: 200)], frozenColumns: 1)
        meta.insertColumn(at: 0)
        #expect(meta.columns == [.init(), .init(width: 90), .init(width: 200)])
        #expect(meta.frozenColumns == 2)
        meta.insertColumn(at: 5)
        #expect(meta.columns.count == 3)
        #expect(meta.frozenColumns == 2)
        meta.deleteColumn(at: 0)
        #expect(meta == SheetMeta(columns: [.init(width: 90), .init(width: 200)], frozenColumns: 1))
        meta.deleteColumn(at: 1)
        #expect(meta == SheetMeta(columns: [.init(width: 90)], frozenColumns: 1))
    }

    @Test func mergeTakesEachSidesChanges() {
        let base = SheetMeta(columns: [.init(width: 100), .init(width: 100)])
        let local = SheetMeta(columns: [.init(width: 150), .init(width: 100)])
        let remote = SheetMeta(columns: [.init(width: 100), .init(width: 80)], frozenColumns: 1, headerRow: false)
        #expect(SheetMeta.merge(base: base, local: local, remote: remote)
            == SheetMeta(columns: [.init(width: 150), .init(width: 80)], frozenColumns: 1, headerRow: false))
    }

    @Test func mergeLocalWinsWhenBothChangeSameField() {
        let base = SheetMeta(columns: [.init(width: 100)], frozenColumns: 0)
        let local = SheetMeta(columns: [.init(width: 150)], frozenColumns: 1)
        let remote = SheetMeta(columns: [.init(width: 80)], frozenColumns: 2)
        #expect(SheetMeta.merge(base: base, local: local, remote: remote) == local)
    }

    @Test func mergeWithoutBaseUsesDefaults() {
        let local = SheetMeta(frozenColumns: 1)
        let remote = SheetMeta(columns: [.init(), .init(width: 220)], headerRow: false)
        #expect(SheetMeta.merge(base: nil, local: local, remote: remote)
            == SheetMeta(columns: [.init(), .init(width: 220)], frozenColumns: 1, headerRow: false))
    }

    @Test func kindMergeFallsBackToTheValidSide() {
        let valid = SheetMeta(frozenColumns: 1).data()
        let broken = Data("{".utf8)
        #expect(CSVMetaKind.merge(base: nil, local: valid, remote: broken) == valid)
        #expect(CSVMetaKind.merge(base: nil, local: broken, remote: valid) == valid)
        #expect(CSVMetaKind.merge(base: nil, local: broken, remote: Data("[".utf8)) == nil)
        let merged = CSVMetaKind.merge(base: SheetMeta().data(), local: SheetMeta(frozenColumns: 1).data(),
                                       remote: SheetMeta(headerRow: false).data())
        #expect(merged == SheetMeta(frozenColumns: 1, headerRow: false).data())
    }

    @Test func companionOfMainFile() throws {
        #expect(CSVMetaKind.companionOf("資料/成績.csv.meta.json") == "資料/成績.csv")
        #expect(TSVMetaKind.companionOf("成績.TSV.meta.json") == "成績.TSV")
        #expect(CSVMetaKind.companionOf("成績.tsv.meta.json") == nil)
        #expect(CSVMetaKind.companionOf("成績.csv") == nil)
        let kinds = try KindRegistry([CSVKind.self, TSVKind.self, CSVMetaKind.self, TSVMetaKind.self])
        #expect(kinds.kind(for: "成績.csv.meta.json")?.id == CSVMetaKind.id)
        #expect(kinds.kind(for: "成績.csv")?.id == CSVKind.id)
        #expect(kinds.mainFile(ofCompanion: "成績.tsv.meta.json") == "成績.tsv")
        #expect(kinds.companionPath("a/成績.csv.meta.json", from: "a/成績.csv", to: "b/期末.csv") == "b/期末.csv.meta.json")
    }
}
