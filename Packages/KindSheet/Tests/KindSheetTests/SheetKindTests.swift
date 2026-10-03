import EasyNotesCore
import Foundation
import Testing
@testable import KindSheet

/// 編碼、索引、改名連結與 Kind 註冊
struct SheetKindTests {
    /// 「中文,a」的 Big5 位元組：中 = A4 A4、文 = A4 E5
    static let big5 = Data([0xA4, 0xA4, 0xA4, 0xE5, 0x2C, 0x61, 0x0D, 0x0A])

    @Test func utf8IsEditable() {
        #expect(csv("名稱\n").encoding == .utf8)
        #expect(csv("\u{FEFF}名稱\n").encoding == .utf8)
        #expect(csv("").isEditable)
    }

    @Test func invalidBytesAreReadOnlyButRoundTrip() {
        let data = Data([0x61, 0x2C, 0xFF, 0xFE, 0x0A])
        let sheet = SheetDocument(data: data, delimiter: CSVKind.delimiter)
        #expect(!sheet.isEditable)
        #expect(sheet.data() == data)
        #expect(SheetDocument.convertToUTF8(Data("已經是 UTF-8\n".utf8)) == nil)
    }

    @Test(.enabled(if: SheetDocument.big5Encoding != nil))
    func big5IsReadOnlyAndConvertsToUTF8() throws {
        let sheet = SheetDocument(data: Self.big5, delimiter: CSVKind.delimiter)
        #expect(sheet.encoding == .big5)
        #expect(!sheet.isEditable)
        #expect(sheet.records.map(\.fields) == [["中文", "a"]])
        #expect(sheet.data() == Self.big5)
        #expect(try #require(SheetDocument.convertToUTF8(Self.big5)) == Data("中文,a\r\n".utf8))
        #expect(CSVKind.index(Self.big5, fileName: "舊.csv").plainText.contains("中文"))
    }

    @Test func registersBothExtensions() throws {
        let registry = try KindRegistry([CSVKind.self, TSVKind.self])
        #expect(registry.kind(for: "資料/表.csv") == CSVKind.self)
        #expect(registry.kind(for: "表.TSV") == TSVKind.self)
        #expect(registry.displayName("資料/表.csv") == "表")
        #expect(!registry.isCompanion("表.csv"))
    }

    @Test func templateIsAHeaderRow() {
        let sheet = csv(String(decoding: CSVKind.template(title: "x"), as: UTF8.self))
        #expect(sheet.records.count == 1)
        #expect(sheet.records[0].fields.count == 2)
        #expect(String(decoding: TSVKind.template(title: "x"), as: UTF8.self).contains("\t"))
    }

    @Test func index() {
        let data = Data("名稱,連結\n蘋果,見 [[水果]] 與 [[價格|價目表]]\n香蕉,[[水果]]\n".utf8)
        let entry = CSVKind.index(data, fileName: "購物.csv")
        #expect(entry.title == "購物")
        #expect(entry.plainText == "名稱 連結\n蘋果 見 [[水果]] 與 [[價格|價目表]]\n香蕉 [[水果]]\n")
        #expect(entry.links == ["水果", "價格"])
        #expect(entry.summary == "CSV · 3 列 · 2 欄")
        #expect(TSVKind.index(Data("a\tb\tc\n".utf8), fileName: "x.tsv").summary == "TSV · 1 列 · 3 欄")
    }

    @Test func indexCapsPlainTextButKeepsAllLinks() {
        let rows = (0..<20_000).map { "第 \($0) 列,一些內容\n" }.joined()
        let entry = CSVKind.index(Data((rows + "最後,[[結尾]]\n").utf8), fileName: "大.csv")
        #expect(entry.plainText.count == plainTextLimit)
        #expect(entry.links == ["結尾"])
        #expect(entry.summary == "CSV · \(20_001.formatted(.number)) 列 · 2 欄")
    }

    @Test func renameLinks() throws {
        let data = Data("\"a\",\"b\"\r\n\"[[舊名]]\",\"x\"\r\n\"見 ![[舊名|別名]]\",\"[[其他]]\"\r\n".utf8)
        let renamed = try #require(CSVKind.renameLinks(in: data, from: "舊名", to: "新,名"))
        #expect(String(decoding: renamed, as: UTF8.self)
                == "\"a\",\"b\"\r\n\"[[新,名]]\",\"x\"\r\n\"見 ![[新,名|別名]]\",\"[[其他]]\"\r\n")
        #expect(CSVKind.renameLinks(in: data, from: "沒有", to: "x") == nil)
        #expect(CSVKind.renameLinks(in: Data([0x5B, 0x5B, 0xFF, 0x5D, 0x5D, 0x0A]), from: "x", to: "y") == nil)
    }

    @Test func renameLinksLeavesOtherRecordsUntouched() throws {
        // 第一列的不必要引號沒有被正規化
        let data = Data("\"a\",b\n[[舊名]],x\n".utf8)
        let renamed = try #require(TSVKind.renameLinks(in: Data("\"a\"\tb\n[[舊名]]\tx\n".utf8), from: "舊名", to: "新名"))
        #expect(String(decoding: renamed, as: UTF8.self) == "\"a\"\tb\n[[新名]]\tx\n")
        #expect(String(decoding: try #require(CSVKind.renameLinks(in: data, from: "舊名", to: "新名")), as: UTF8.self)
                == "\"a\",b\n[[新名]],x\n")
    }
}
