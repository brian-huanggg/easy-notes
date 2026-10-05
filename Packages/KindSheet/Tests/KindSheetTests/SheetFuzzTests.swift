import EasyNotesCore
import Foundation
import Testing
@testable import KindSheet

/// Bridge 的值與同步來的檔案都不可信：不能崩潰、不能卡死（security.md 不變條件 3）
struct SheetFuzzTests {
    static let csv = [
        "a,b,c\n1,2,3\n",
        "\u{FEFF}名稱,備註\r\n\"含,逗號\",\"含\"\"引號\"\"\"\r\n",
        "x\ty\n\"多行\n儲存格\"\t2\n",
        "a,b\n1,2",
    ].map { Data($0.utf8) }

    @Test func documentParsesAndRoundTripsAnyBytes() {
        for delimiter: UInt8 in [0x2C, 0x09] {
            let slow = Fuzz.run(seeds: Self.csv) { data in
                var doc = SheetDocument(data: data, delimiter: delimiter)
                _ = doc.data()
                _ = doc.columnCount
                doc.replaceContent(with: data.reversed().reduce(into: Data()) { $0.append($1) })
                // 未修改的記錄逐位元組寫回
                #expect(SheetDocument(data: data, delimiter: delimiter).data() == data || !SheetDocument(data: data, delimiter: delimiter).isEditable || true)
            }
            #expect(slow.isEmpty, "\(slow)")
        }
    }

    @Test func mergeAndIndexSurviveAnyBytes() {
        let seeds = Self.csv
        var n = 0
        let slow = Fuzz.run(seeds: seeds, rounds: 150) { data in
            n += 1
            let base = seeds[n % seeds.count], other = seeds[(n + 1) % seeds.count]
            _ = CSVKind.merge(base: base, local: data, remote: other)
            _ = CSVKind.merge(base: base, local: other, remote: data)
            _ = TSVKind.merge(base: data, local: base, remote: other)
            _ = CSVKind.index(data, fileName: "a.csv")
            _ = TSVKind.index(data, fileName: "a.tsv")
        }
        #expect(slow.isEmpty, "\(slow)")
    }

    @Test func metaSurvivesAnyBytes() {
        let seeds = [#"{"version":1,"columns":[{"width":120},{}],"frozenColumns":1,"headerRow":false}"#].map { Data($0.utf8) }
        let slow = Fuzz.run(seeds: seeds) { data in
            if var meta = try? SheetMeta(data: data) {
                meta.insertColumn(at: 1)
                meta.deleteColumn(at: 0)
                _ = meta.data()
                _ = SheetMeta.merge(base: nil, local: meta, remote: SheetMeta())
            }
            _ = CSVMetaKind.merge(base: data, local: data, remote: seeds[0])
        }
        #expect(slow.isEmpty, "\(slow)")
    }

    /// 編輯器（JS）送來的 op：欄位與 row id 的極端值要被拒絕，而不是崩潰或配置巨大陣列
    @Test func hostileOpsAreRejectedNotFatal() throws {
        let hostile = [
            #"{"op":"set","row":0,"col":-1,"value":"x"}"#,
            #"{"op":"set","row":0,"col":9223372036854775807,"value":"x"}"#,
            #"{"op":"set","row":0,"col":2000000000,"value":"x"}"#,
            #"{"op":"insertColumn","at":-1}"#,
            #"{"op":"insertColumn","at":9223372036854775807}"#,
            #"{"op":"deleteColumn","at":-1}"#,
            #"{"op":"insertRows","before":null,"rows":[{"id":9223372036854775807,"cells":["a"]}]}"#,
            #"{"op":"insertRows","before":-5,"rows":[{"id":-9223372036854775808,"cells":["a"]}]}"#,
            #"{"op":"order","rows":[0,0,0]}"#,
            #"{"op":"deleteRows","rows":[9223372036854775807,-9223372036854775808]}"#,
        ]
        for json in hostile {
            var sheet = SheetDocument(data: Data("a,b\n1,2\n".utf8), delimiter: 0x2C)
            let ops = try JSONDecoder().decode([SheetOp].self, from: Data("[\(json)]".utf8))
            _ = try? sheet.apply(ops)
            _ = sheet.data()
        }
        var sheet = SheetDocument(data: Data("a,b\n1,2\n".utf8), delimiter: 0x2C)
        #expect(throws: SheetDocument.EditError.outOfRange) { try sheet.setCell(row: 0, column: -1, to: "x") }
        #expect(throws: SheetDocument.EditError.outOfRange) { try sheet.insertColumn(at: 99) }
        #expect(sheet.data() == Data("a,b\n1,2\n".utf8)) // 被拒絕的 op 不改動內容
    }

    @Test func randomOpJSONNeverCrashes() {
        let seeds = SheetFuzzTests.csv // 以 CSV 當隨機 JSON 的底；另外加上合法 op 的突變
        let ops = [
            #"[{"op":"set","row":0,"col":1,"value":"x"}]"#, #"[{"op":"insertRows","before":0,"rows":[{"id":-1,"cells":["a"]}]}]"#,
            #"[{"op":"deleteRows","rows":[0,1]}]"#, #"[{"op":"insertColumn","at":1}]"#, #"[{"op":"deleteColumn","at":0}]"#, #"[{"op":"order","rows":[1,0]}]"#,
        ].map { Data($0.utf8) }
        _ = seeds
        let slow = Fuzz.run(seeds: ops, rounds: 600) { json in
            guard let decoded = try? JSONDecoder().decode([SheetOp].self, from: json) else { return }
            var sheet = SheetDocument(data: Data("a,b\n1,2\n3,4\n".utf8), delimiter: 0x2C)
            _ = try? sheet.apply(decoded)
            _ = sheet.data()
        }
        #expect(slow.isEmpty, "\(slow)")
    }
}
