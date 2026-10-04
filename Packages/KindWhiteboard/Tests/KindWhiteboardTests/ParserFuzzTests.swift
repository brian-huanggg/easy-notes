import EasyNotesCore
import ExcalidrawKit
import Foundation
import Testing
@testable import KindWhiteboard

/// `.excalidraw` 可能被竄改或來自別的工具：解析、索引、合併、序列化都不能崩潰（JSONSerialization 對 inf / NaN 會丟 ObjC 例外）
struct ParserFuzzTests {
    static let seeds: [Data] = [
        #"{"type":"excalidraw","version":2,"elements":[{"id":"a","type":"text","text":"你好","version":3,"x":1,"y":2,"isDeleted":false},{"id":"b","type":"freedraw","points":[[0,0],[1,1]],"version":1}],"appState":{},"files":{}}"#,
        #"{"type":"excalidraw","elements":[{"id":"n","type":"rectangle","link":"easynotes://note/a.md","version":1}]}"#,
        "",
    ].map { Data($0.utf8) }

    @Test func sceneSurvivesAnyBytes() {
        var n = 0
        let slow = Fuzz.run(seeds: Self.seeds, rounds: 500) { data in
            n += 1
            _ = InkKind.index(data, fileName: "a.excalidraw")
            _ = InkKind.merge(base: nil, local: data, remote: Self.seeds[n % Self.seeds.count])
            _ = InkKind.merge(base: nil, local: Self.seeds[n % Self.seeds.count], remote: data)
            _ = InkKind.renameLinks(in: data, from: "a", to: "b")
            if let scene = try? ExcalidrawScene(data: data) { _ = try? scene.data() }
        }
        #expect(slow.isEmpty, "\(slow)")
    }

    /// 合法 JSON 但數值溢位 / 極端巢狀
    @Test func extremeNumbersAndNestingDoNotCrash() {
        let inputs = [
            #"{"type":"excalidraw","elements":[{"id":"a","type":"rectangle","x":1e999,"y":-1e999,"version":1e999,"width":1e308}]}"#,
            #"{"type":"excalidraw","elements":[{"id":"a","type":"freedraw","points":[[1e999,0],[0,-1e999]],"version":9223372036854775807}]}"#,
            #"{"type":"excalidraw","elements":[{"id":"a","version":-9223372036854775808,"versionNonce":18446744073709551615}]}"#,
            #"{"type":"excalidraw","elements":"x","appState":[],"files":3}"#,
            #"{"type":"excalidraw","elements":[null,1,"s",[],{}]}"#,
            "{\"type\":\"excalidraw\",\"elements\":" + String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000) + "}",
            "{\"type\":\"excalidraw\",\"x\":" + String(repeating: "[", count: 200_000),
        ].map { Data($0.utf8) }
        for data in inputs {
            _ = InkKind.index(data, fileName: "a.excalidraw")
            _ = InkKind.merge(base: nil, local: data, remote: Self.seeds[0])
            _ = InkKind.merge(base: nil, local: Self.seeds[0], remote: data)
            if let scene = try? ExcalidrawScene(data: data) { _ = try? scene.data() }
        }
    }
}
