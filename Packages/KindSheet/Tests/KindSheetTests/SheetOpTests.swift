import Foundation
import Testing
@testable import KindSheet

/// Bridge 的 ops、JS 指定 id 的新增列、重排、外部變動時保留 row id
struct SheetOpTests {
    func decode(_ json: String) throws -> [SheetOp] {
        try JSONDecoder().decode([SheetOp].self, from: Data(json.utf8))
    }

    @Test func decodesOps() throws {
        let ops = try decode("""
            [{"op":"set","row":3,"col":1,"value":"x"},
             {"op":"insertRows","before":null,"rows":[{"id":-1,"cells":["a","b"]}]},
             {"op":"insertRows","before":2,"rows":[]},
             {"op":"deleteRows","rows":[1,2]},
             {"op":"insertColumn","at":2},
             {"op":"deleteColumn","at":0},
             {"op":"order","rows":[0,2,1]}]
            """)
        #expect(ops == [
            .set(row: 3, column: 1, value: "x"),
            .insertRows(before: nil, rows: [.init(id: -1, cells: ["a", "b"])]),
            .insertRows(before: 2, rows: []),
            .deleteRows([1, 2]),
            .insertColumn(at: 2),
            .deleteColumn(at: 0),
            .order([0, 2, 1]),
        ])
        #expect(throws: DecodingError.self) { try decode(#"[{"op":"explode"}]"#) }
    }

    @Test func applyOps() throws {
        var sheet = csv("名稱,數量\n蘋果,3\n香蕉,5\n")
        try sheet.apply(try decode("""
            [{"op":"set","row":1,"col":1,"value":"4"},
             {"op":"insertRows","before":2,"rows":[{"id":-1,"cells":["芒果"]}]},
             {"op":"insertRows","before":null,"rows":[{"id":-2,"cells":["西瓜","1"]}]},
             {"op":"set","row":-1,"col":1,"value":"8"}]
            """))
        #expect(string(sheet) == "名稱,數量\n蘋果,4\n芒果,8\n香蕉,5\n西瓜,1\n")
        #expect(sheet.records.map(\.id) == [0, 1, -1, 2, -2])
        try sheet.apply([.deleteRows([-1]), .order([0, -2, 2, 1])])
        #expect(string(sheet) == "名稱,數量\n西瓜,1\n香蕉,5\n蘋果,4\n")
    }

    @Test func insertWithIDsRejectsDuplicates() {
        var sheet = csv("a\nb\n")
        #expect(throws: SheetDocument.EditError.duplicateRow(1)) { try sheet.insertRows([["x"]], at: 0, ids: [1]) }
        #expect(throws: SheetDocument.EditError.duplicateRow(-1)) { try sheet.insertRows([["x"], ["y"]], at: 0, ids: [-1, -1]) }
        #expect(throws: SheetDocument.EditError.unknownRow(9)) {
            try sheet.apply([.insertRows(before: 9, rows: [.init(id: -3, cells: ["x"])])])
        }
        #expect(string(sheet) == "a\nb\n")
    }

    @Test func swiftIDsContinueAfterJSIDs() throws {
        var sheet = csv("a\n")
        try sheet.insertRows([["x"]], at: 1, ids: [7])
        #expect(try sheet.insertRows([["y"]], at: 2) == [8])
    }

    @Test func reorderKeepsRecordBytes() throws {
        var sheet = csv("\"h\",x\nc,3\n\"a\",1\nb,2")
        try sheet.reorderRows([0, 2, 3, 1])
        // 沒有檔尾換行：新的最後一筆沒有換行，原本的最後一筆補上換行；各列內容逐位元組不變
        #expect(string(sheet) == "\"h\",x\n\"a\",1\nb,2\nc,3")
        #expect(sheet.records.allSatisfy { !$0.isModified })
    }

    @Test func reorderRequiresEveryRowOnce() {
        var sheet = csv("a\nb\nc\n")
        #expect(throws: SheetDocument.EditError.unknownRow(2)) { try sheet.reorderRows([0, 1]) }
        #expect(throws: SheetDocument.EditError.unknownRow(0)) { try sheet.reorderRows([0, 0, 1, 2]) }
        #expect(throws: SheetDocument.EditError.unknownRow(5)) { try sheet.reorderRows([0, 1, 5]) }
    }

    @Test func replaceContentKeepsIDs() throws {
        var sheet = csv("a\nb\nc\n")
        try sheet.insertRows([["d"]], at: 3, ids: [-1])
        #expect(sheet.records.map(\.id) == [0, 1, 2, -1])

        // 改掉 b、刪掉 c、在前面插入 z：a 與 d 沿用，b 的位置被改掉也沿用，新列給新 id
        sheet.replaceContent(with: Data("z\na\nB\nd\n".utf8))
        #expect(sheet.records.map(\.fields) == [["z"], ["a"], ["B"], ["d"]])
        #expect(sheet.records.map(\.id) == [3, 0, 1, -1])
        #expect(string(sheet) == "z\na\nB\nd\n")

        sheet.replaceContent(with: Data("B\nd\nnew\n".utf8))
        #expect(sheet.records.map(\.id) == [1, -1, 4])
        #expect(try sheet.insertRows([["x"]], at: 0) == [5])
    }

    @Test func replaceContentAdoptsNewStyleAndEncoding() {
        var sheet = SheetDocument(data: Data([0x61, 0xFF, 0x0A]), delimiter: CSVKind.delimiter)
        #expect(!sheet.isEditable)
        sheet.replaceContent(with: Data("\u{FEFF}a,b\r\n".utf8))
        #expect(sheet.isEditable)
        #expect(sheet.style.hasBOM && sheet.style.lineEnding == .crlf)
        #expect(string(sheet) == "\u{FEFF}a,b\r\n")
    }
}
