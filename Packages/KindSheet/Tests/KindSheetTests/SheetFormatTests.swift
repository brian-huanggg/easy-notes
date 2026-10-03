import Foundation
import Testing
@testable import KindSheet

func csv(_ text: String) -> SheetDocument { SheetDocument(data: Data(text.utf8), delimiter: CSVKind.delimiter) }
func tsv(_ text: String) -> SheetDocument { SheetDocument(data: Data(text.utf8), delimiter: TSVKind.delimiter) }
func string(_ sheet: SheetDocument) -> String { String(decoding: sheet.data(), as: UTF8.self) }

/// RFC 4180 解析、風格偵測，以及未修改的檔案逐位元組寫回
struct SheetFormatTests {
    static let roundTrip = [
        "",
        "a,b,c\n1,2,3\n",
        "a,b,c\r\n1,2,3\r\n",
        "a,b,c\n1,2,3",
        "\u{FEFF}名稱,數量\n蘋果,3\n",
        "\"a\",\"b\"\n\"1\",\"2\"\n",
        "\"含,逗號\",\"含\"\"引號\"\"\",\"跨\n行\"\n",
        "中文,emoji 😀,👨‍👩‍👧\n",
        "a,b,c\n1\n1,2,3,4\n",          // 欄數不一
        "a,b\n\n\n1,2\n",               // 空白行
        "a,\"未關閉\n的引號",             // 未關閉的引號延伸到檔尾
        "a\"b,\"c\"d\n",                  // 欄位中間的引號、結尾引號後的字元
        "a,b\r1,2\n",                     // 單獨的 CR 是內容
        "a,b\r\n1,2\n3,4\r\n",            // 混合換行
        "  a , b \n",                     // 空白保留
        ",,\n,,\n",
    ]

    @Test(arguments: roundTrip) func unmodifiedFilesAreByteIdentical(_ text: String) {
        #expect(string(csv(text)) == text)
        let tab = text.replacingOccurrences(of: ",", with: "\t")
        #expect(string(tsv(tab)) == tab)
    }

    @Test func parsesQuotedFields() {
        let sheet = csv("\"含,逗號\",\"含\"\"引號\"\"\",\"跨\r\n行\",plain\n")
        #expect(sheet.records.map(\.fields) == [["含,逗號", "含\"引號\"", "跨\r\n行", "plain"]])
    }

    @Test func recordsAndBlankLines() {
        #expect(csv("").records.isEmpty)
        #expect(csv("\n").records.map(\.fields) == [[""]])
        #expect(csv("a\n\nb").records.map(\.fields) == [["a"], [""], ["b"]])
        #expect(csv("a,b,c\n1\n").columnCount == 3)
        #expect(csv("a,b,c\n1\n").records[1].fields == ["1"])
    }

    @Test func rowIDsAreSequential() {
        #expect(csv("a\nb\nc\n").records.map(\.id) == [0, 1, 2])
    }

    @Test func tsvUsesTabsOnly() {
        #expect(tsv("a,b\tc\n").records.map(\.fields) == [["a,b", "c"]])
    }

    @Test func detectsStyle() {
        let plain = csv("a,b\n1,2\n").style
        #expect(plain.lineEnding == .lf && !plain.quoteAll && !plain.hasBOM && plain.trailingNewline)

        #expect(csv("a\r\nb\r\nc\n").style.lineEnding == .crlf)
        #expect(csv("a\nb\nc\r\n").style.lineEnding == .lf)
        #expect(csv("\u{FEFF}a\n").style.hasBOM)
        #expect(!csv("a\nb").style.trailingNewline)
        #expect(csv("").style.trailingNewline)

        #expect(csv("\"a\",\"b\"\n\n\"1\",\"\"\n").style.quoteAll)
        #expect(!csv("\"a\",b\n").style.quoteAll)
        #expect(!csv("\n").style.quoteAll)
    }

    @Test func bomIsNotPartOfTheFirstField() {
        #expect(csv("\u{FEFF}名稱,數量\n").records[0].fields == ["名稱", "數量"])
    }

    @Test func encodeQuotesOnlyWhenNeeded() {
        let style = SheetDocument.Style(delimiter: CSVKind.delimiter)
        let encoded = SheetDocument.encode(["a", "b,c", "d\"e", "f\ng", "h\ri", ""], style: style)
        #expect(String(decoding: encoded, as: UTF8.self) == "a,\"b,c\",\"d\"\"e\",\"f\ng\",\"h\ri\",")

        var all = style
        all.quoteAll = true
        #expect(String(decoding: SheetDocument.encode(["a", ""], style: all), as: UTF8.self) == "\"a\",\"\"")
    }

    @Test func encodedFieldsParseBack() {
        let fields = ["含,逗號", "含\"引號\"", "跨\r\n行", "", " 空白 ", "😀"]
        for delimiter in [CSVKind.delimiter, TSVKind.delimiter] {
            let style = SheetDocument.Style(delimiter: delimiter)
            let data = SheetDocument.encode(fields, style: style) + Data("\n".utf8)
            #expect(SheetDocument(data: data, delimiter: delimiter).records.map(\.fields) == [fields])
        }
    }

    @Test func tenThousandRowsRoundTrip() {
        let text = (0..<10_000).map { "\($0),名稱 \($0),\"備註, \($0)\"\n" }.joined()
        let sheet = csv(text)
        #expect(sheet.records.count == 10_000)
        #expect(string(sheet) == text)
    }
}
