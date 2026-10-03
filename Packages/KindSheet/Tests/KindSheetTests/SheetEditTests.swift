import Foundation
import Testing
@testable import KindSheet

/// 編輯後只有改到的記錄重新產生，其餘逐位元組不變
struct SheetEditTests {
    @Test func setCellRewritesOnlyThatRecord() throws {
        // 第一列刻意用不必要的引號：沒改到就保持原樣
        var sheet = csv("\"a\",b\r\nx,y\r\n1,2\r\n")
        try sheet.setCell(row: 2, column: 1, to: "含,逗號")
        #expect(string(sheet) == "\"a\",b\r\nx,y\r\n1,\"含,逗號\"\r\n")
        #expect(sheet.records.map(\.isModified) == [false, false, true])
    }

    @Test func setCellFollowsQuoteAllStyle() throws {
        var sheet = csv("\"a\",\"b\"\n\"1\",\"2\"\n")
        try sheet.setCell(row: 1, column: 0, to: "新")
        #expect(string(sheet) == "\"a\",\"b\"\n\"新\",\"2\"\n")
    }

    @Test func settingTheSameValueIsNotAModification() throws {
        var sheet = csv("\"a\",b\n")
        try sheet.setCell(row: 0, column: 0, to: "a")
        try sheet.setCell(row: 0, column: 5, to: "")
        #expect(string(sheet) == "\"a\",b\n")
    }

    @Test func raggedRowsAreOnlyExtendedToTheEditedColumn() throws {
        var sheet = csv("a,b,c,d\n1\n")
        try sheet.setCell(row: 1, column: 2, to: "x")
        #expect(string(sheet) == "a,b,c,d\n1,,x\n")
    }

    @Test func unknownRowThrows() {
        var sheet = csv("a\n")
        #expect(throws: SheetDocument.EditError.unknownRow(9)) { try sheet.setCell(row: 9, column: 0, to: "x") }
    }

    @Test func insertRowsPadsToColumnCount() throws {
        var sheet = csv("a,b,c\r\n1,2,3\r\n")
        let ids = try sheet.insertRows([["x"], []], at: 1)
        #expect(ids == [2, 3])
        #expect(string(sheet) == "a,b,c\r\nx,,\r\n,,\r\n1,2,3\r\n")
        #expect(sheet.index(ofRow: 2) == 1)
    }

    @Test func appendKeepsMissingTrailingNewline() throws {
        var sheet = csv("a,b\n1,2")
        try sheet.insertRows([["3", "4"]], at: 2)
        #expect(string(sheet) == "a,b\n1,2\n3,4")
        // 原本的最後一筆只多了換行，內容沒有重新產生
        #expect(!sheet.records[1].isModified)
    }

    @Test func insertIntoEmptyFile() throws {
        var sheet = csv("")
        try sheet.insertRows([["a", "b"]], at: 0)
        #expect(string(sheet) == "a,b\n")
    }

    @Test func deleteRows() throws {
        var sheet = csv("a\nb\nc\nd\n")
        try sheet.deleteRows([1, 3])
        #expect(string(sheet) == "a\nc\n")
    }

    @Test func deletingTheLastRowKeepsMissingTrailingNewline() throws {
        var sheet = csv("a\nb\nc")
        try sheet.deleteRows([2])
        #expect(string(sheet) == "a\nb")
    }

    @Test func insertAndDeleteColumns() throws {
        var sheet = csv("a,b,c\n1\n\n1,2,3\n")
        try sheet.insertColumn(at: 1)
        // 比插入位置短的列與空白行不變
        #expect(string(sheet) == "a,,b,c\n1\n\n1,,2,3\n")
        try sheet.deleteColumn(at: 2)
        #expect(string(sheet) == "a,,c\n1\n\n1,,3\n")
        try sheet.deleteColumn(at: 0)
        #expect(string(sheet) == ",c\n\n\n,3\n")
        #expect(sheet.records[1].fields == [""])
    }

    @Test func appendColumn() throws {
        var sheet = csv("a,b\n1\n1,2\n")
        try sheet.insertColumn(at: 2)
        #expect(string(sheet) == "a,b,\n1\n1,2,\n")
        #expect(sheet.columnCount == 3)
    }

    @Test func readOnlySheetsRejectEdits() {
        var sheet = SheetDocument(data: Data([0xA4, 0xA4, 0x2C, 0xFF, 0x0A]), delimiter: CSVKind.delimiter)
        #expect(!sheet.isEditable)
        #expect(throws: SheetDocument.EditError.readOnly) { try sheet.setCell(row: 0, column: 0, to: "x") }
        #expect(throws: SheetDocument.EditError.readOnly) { try sheet.insertRows([["x"]], at: 0) }
        #expect(throws: SheetDocument.EditError.readOnly) { try sheet.deleteRows([0]) }
        #expect(throws: SheetDocument.EditError.readOnly) { try sheet.insertColumn(at: 0) }
        #expect(throws: SheetDocument.EditError.readOnly) { try sheet.deleteColumn(at: 0) }
    }
}
