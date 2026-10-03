import Foundation
import Testing
@testable import KindSheet

/// 以記錄為單位的 diff3 + 同一記錄的儲存格三方合併
struct SheetMergeTests {
    func merge(_ base: String?, _ local: String, _ remote: String, kind: any SheetKind.Type = CSVKind.self) -> String? {
        kind.merge(base: base.map { Data($0.utf8) }, local: Data(local.utf8), remote: Data(remote.utf8))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    let base = "名稱,數量,備註\n蘋果,3,\n香蕉,5,\n橘子,2,\n葡萄,1,\n"

    @Test func trivialCases() {
        #expect(merge(base, base, "x\n") == "x\n")
        #expect(merge(base, "x\n", base) == "x\n")
        #expect(merge(base, "x\n", "x\n") == "x\n")
    }

    @Test func withoutBaseOnlyIdenticalContentMerges() {
        #expect(merge(nil, "a\n", "a\n") == "a\n")
        #expect(merge(nil, "a\n", "b\n") == nil)
    }

    @Test func differentRowsMerge() {
        let local = base.replacingOccurrences(of: "蘋果,3,", with: "蘋果,4,")
        let remote = base.replacingOccurrences(of: "葡萄,1,", with: "葡萄,1,已買")
        #expect(merge(base, local, remote) == "名稱,數量,備註\n蘋果,4,\n香蕉,5,\n橘子,2,\n葡萄,1,已買\n")
    }

    @Test func adjacentRowsMerge() {
        let local = base.replacingOccurrences(of: "香蕉,5,", with: "香蕉,6,")
        let remote = base.replacingOccurrences(of: "橘子,2,", with: "橘子,2,酸")
        #expect(merge(base, local, remote) == "名稱,數量,備註\n蘋果,3,\n香蕉,6,\n橘子,2,酸\n葡萄,1,\n")
    }

    @Test func differentCellsOfTheSameRowMerge() {
        let local = base.replacingOccurrences(of: "香蕉,5,", with: "香蕉,6,")
        let remote = base.replacingOccurrences(of: "香蕉,5,", with: "香蕉,5,\"熟, 黃\"")
        #expect(merge(base, local, remote) == "名稱,數量,備註\n蘋果,3,\n香蕉,6,\"熟, 黃\"\n橘子,2,\n葡萄,1,\n")
    }

    @Test func sameCellDifferentValuesConflicts() {
        let local = base.replacingOccurrences(of: "香蕉,5,", with: "香蕉,6,")
        let remote = base.replacingOccurrences(of: "香蕉,5,", with: "香蕉,7,")
        #expect(merge(base, local, remote) == nil)
    }

    @Test func sameChangeOnBothSidesIsNotAConflict() {
        let both = base.replacingOccurrences(of: "香蕉,5,", with: "香蕉,6,")
        let remote = both.replacingOccurrences(of: "葡萄,1,", with: "葡萄,9,")
        #expect(merge(base, both, remote) == remote)
    }

    @Test func deleteVersusEditConflicts() {
        let local = base.replacingOccurrences(of: "香蕉,5,\n", with: "")
        let remote = base.replacingOccurrences(of: "香蕉,5,", with: "香蕉,6,")
        #expect(merge(base, local, remote) == nil)
    }

    @Test func insertAndDeleteInDifferentPlaces() {
        let local = base.replacingOccurrences(of: "蘋果,3,\n", with: "蘋果,3,\n芒果,8,\n")
        let remote = base.replacingOccurrences(of: "葡萄,1,\n", with: "")
        #expect(merge(base, local, remote) == "名稱,數量,備註\n蘋果,3,\n芒果,8,\n香蕉,5,\n橘子,2,\n")
    }

    @Test func bothAppendingKeepsBothLocalFirst() {
        #expect(merge(base, base + "西瓜,1,\n", base + "鳳梨,2,\n") == base + "西瓜,1,\n鳳梨,2,\n")
    }

    @Test func appendWithoutTrailingNewline() {
        let noNewline = String(base.dropLast())
        // 本地沒有檔尾換行、遠端在檔尾附加：結果依本地風格（沒有檔尾換行）
        #expect(merge(noNewline, noNewline.replacingOccurrences(of: "蘋果,3,", with: "蘋果,4,"),
                      noNewline + "\n西瓜,1,")
                == "名稱,數量,備註\n蘋果,4,\n香蕉,5,\n橘子,2,\n葡萄,1,\n西瓜,1,")
        // 兩邊都在檔尾附加
        #expect(merge(noNewline, noNewline + "\n西瓜,1,", noNewline + "\n鳳梨,2,")
                == noNewline + "\n西瓜,1,\n鳳梨,2,")
        // 改最後一筆的不同儲存格
        #expect(merge(noNewline, noNewline.replacingOccurrences(of: "葡萄,1,", with: "葡萄,2,"),
                      noNewline.replacingOccurrences(of: "葡萄,1,", with: "葡萄,1,紫"))
                == "名稱,數量,備註\n蘋果,3,\n香蕉,5,\n橘子,2,\n葡萄,2,紫")
    }

    @Test func multilineRecordsAreOneUnit() {
        let base = "a,b\n\"第一行\n第二行\",1\nx,2\n"
        let local = "a,b\n\"第一行\n第二行\",9\nx,2\n"
        let remote = "a,b\n\"第一行\n第二行（改）\",1\nx,2\n"
        #expect(merge(base, local, remote) == "a,b\n\"第一行\n第二行（改）\",9\nx,2\n")
    }

    @Test func crlfAndBomArePreserved() {
        let base = "\u{FEFF}a,b\r\n1,2\r\n3,4\r\n"
        #expect(merge(base, "\u{FEFF}a,b\r\n1,X\r\n3,4\r\n", "\u{FEFF}a,b\r\n1,2\r\nY,4\r\n")
                == "\u{FEFF}a,b\r\n1,X\r\nY,4\r\n")
        #expect(merge(base, "\u{FEFF}a,b\r\n1,2\r\n3,4\r\n5,6\r\n", "\u{FEFF}A,b\r\n1,2\r\n3,4\r\n")
                == "\u{FEFF}A,b\r\n1,2\r\n3,4\r\n5,6\r\n")
    }

    @Test func cellMergeFollowsLocalQuoteStyle() {
        let base = "\"a\",\"b\"\n\"1\",\"2\"\n"
        #expect(merge(base, "\"a\",\"b\"\n\"X\",\"2\"\n", "\"a\",\"b\"\n\"1\",\"Y\"\n") == "\"a\",\"b\"\n\"X\",\"Y\"\n")
    }

    @Test func addingAColumnConflictsWithCellEdits() {
        let base = "a,b\n1,2\n"
        #expect(merge(base, "a,,b\n1,,2\n", "a,b\n1,X\n") == nil)
    }

    @Test func tsvMerges() {
        let base = "a\tb\n1\t2\n"
        #expect(merge(base, "a\tb\nX\t2\n", "a\tb\n1\tY\n", kind: TSVKind.self) == "a\tb\nX\tY\n")
    }

    @Test func readOnlyFilesOnlyMergeWhenIdentical() {
        let bad = Data([0x61, 0xFF, 0x0A])
        #expect(CSVKind.merge(base: bad, local: bad + Data("b\n".utf8), remote: Data("c\n".utf8) + bad) == nil)
        #expect(CSVKind.merge(base: Data(), local: bad, remote: bad) == bad)
    }
}
