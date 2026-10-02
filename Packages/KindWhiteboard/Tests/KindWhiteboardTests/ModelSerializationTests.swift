import Foundation
import Testing
import EasyNotesCore
@testable import KindWhiteboard

/// 4a：序列化、共用修改路徑、fractional index
struct ModelSerializationTests {
    @Test func excalidrawExportRoundTripsUnchanged() throws {
        let original = try Fixture.data()
        let scene = try ExcalidrawScene(data: original)
        let written = try Fixture.json(scene.data())
        let expected = try Fixture.json(original)
        // 整份文件（含未知的 appState 欄位、files）逐欄位相同
        #expect(NSDictionary(dictionary: written).isEqual(to: expected))
        #expect(scene.elements.count == 14)
    }

    @Test func typedWrapperKeepsUnknownTypesAndFields() throws {
        let scene = try ExcalidrawScene(data: Fixture.data())
        let types = Dictionary(uniqueKeysWithValues: scene.orderedElements.map { ($0.id, $0.type) })
        #expect(types["rect-1"] == .rectangle)
        #expect(types["ell-1"] == .ellipse)
        #expect(types["diamond-1"] == .diamond)
        #expect(types["line-1"] == .line)
        #expect(types["arrow-1"] == .arrow)
        #expect(types["elbow-1"] == .arrow)
        #expect(types["text-1"] == .text)
        #expect(types["img-1"] == .image)
        #expect(types["frame-1"] == .frame)
        #expect(types["free-1"] == .freedraw)
        #expect(types["embed-1"] == .unknown("embeddable"))
        #expect(types["future-1"] == .unknown("magicframe"))

        // 包裝只是原始字典的檢視：不透過 mutate，寫回的內容不變
        let rewritten = scene.orderedElements.map(\.raw)
        #expect(NSArray(array: rewritten).isEqual(to: scene.elements))

        let elbow = try #require(scene.element("elbow-1"))
        #expect(elbow.isElbowArrow)
        #expect(elbow.points.count == 4)

        let arrow = try #require(scene.element("arrow-1"))
        #expect(arrow.binding(.start) == Binding(elementId: "rect-1", focus: 0, gap: 5, fixedPoint: CGPoint(x: 1.025, y: 0.5)))
        #expect(scene.element("text-1")?.containerId == "rect-1")
        #expect(scene.element("rect-1")?.frameId == "frame-1")
        #expect(scene.element("rect-1")?.boundElements.map(\.id) == ["arrow-1", "text-1"])
    }

    @Test func unrelatedEditsLeaveOtherElementsByteForByte() throws {
        var scene = try ExcalidrawScene(data: Fixture.data())
        let before = scene.elements
        scene.mutate("rect-1") { $0.x += 10 }
        for (old, new) in zip(before, scene.elements) where old["id"] as? String != "rect-1" {
            #expect(NSDictionary(dictionary: old).isEqual(to: new))
        }
        #expect(scene.element("future-1")?.raw["futureField"] != nil)
    }

    @Test func mutateChangesOnlyVersionFieldsAndTheEditedField() throws {
        var scene = try ExcalidrawScene(data: Fixture.data())
        let before = try #require(scene.element("rect-1")).raw

        #expect(scene.mutate("rect-1") { $0.x = 123 })
        let after = try #require(scene.element("rect-1")).raw

        let changed = Set(before.keys.filter { !((before[$0] as? NSObject)?.isEqual(after[$0]) ?? false) })
        #expect(changed == ["x", "version", "versionNonce", "updated"])
        #expect(after["x"] as? Double == 123)
        #expect(after["version"] as? Int == (before["version"] as! Int) + 1)
        #expect(after["versionNonce"] as? Int != before["versionNonce"] as? Int)
        #expect((after["updated"] as! Int) > (before["updated"] as! Int))
        #expect(Set(after.keys) == Set(before.keys))
    }

    @Test func mutateWithoutChangeKeepsVersion() throws {
        var scene = try ExcalidrawScene(data: Fixture.data())
        let before = try #require(scene.element("rect-1")).raw
        #expect(!scene.mutate("rect-1") { $0.x = $0.x })
        #expect(NSDictionary(dictionary: before).isEqual(to: try #require(scene.element("rect-1")).raw))
        #expect(!scene.mutate("missing") { $0.x = 1 })
    }

    // MARK: fractional index

    @Test func fractionalIndexMatchesReferenceImplementation() throws {
        // rocicorp/fractional-indexing 的測試向量
        #expect(try FractionalIndex.between(nil, nil) == "a0")
        #expect(try FractionalIndex.between("a0", nil) == "a1")
        #expect(try FractionalIndex.between("a1", nil) == "a2")
        #expect(try FractionalIndex.between(nil, "a0") == "Zz")
        #expect(try FractionalIndex.between("a0", "a1") == "a0V")
        #expect(try FractionalIndex.between("a0V", "a1") == "a0l")
        #expect(try FractionalIndex.between("Zz", "a0") == "ZzV")
        #expect(try FractionalIndex.between("Zz", "a1") == "a0")
        #expect(try FractionalIndex.between("a0", "a0V") == "a0G")
        #expect(try FractionalIndex.between("a1", "a1V") == "a1G")
        #expect(try FractionalIndex.between(nil, nil, count: 5) == ["a0", "a1", "a2", "a3", "a4"])
        // n 個：先取中點，再遞迴兩側（與參考實作的 generateNKeysBetween 相同）
        #expect(try FractionalIndex.between("a0", "a2", count: 3) == ["a0V", "a1", "a1V"])
        #expect(throws: (any Error).self) { try FractionalIndex.between("a1", "a0") }
        #expect(!FractionalIndex.isValid("a00")) // 小數部分不能以 0 結尾
    }

    @Test func insertingBetweenTwoElements100TimesKeepsOrderAndValidIndex() throws {
        var scene = ExcalidrawScene()
        let first = Element.rectangle(x: 0, y: 0, width: 10, height: 10)
        let last = Element.rectangle(x: 0, y: 0, width: 10, height: 10)
        scene.insert(first); scene.insert(last)

        var inserted: [String] = []
        for i in 0..<100 {
            let el = Element.rectangle(x: Double(i), y: 0, width: 10, height: 10)
            scene.insert(el, at: 1) // 永遠插在第一個與（上一次插入的）之間
            inserted.insert(el.id, at: 0)
        }
        let ordered = scene.orderedElements
        #expect(ordered.map(\.id) == [first.id] + inserted + [last.id])
        let keys = try ordered.map { try #require($0.index) }
        #expect(keys.allSatisfy(FractionalIndex.isValid))
        #expect(zip(keys, keys.dropFirst()).allSatisfy { FractionalIndex.less($0, $1) })
        // 陣列順序也同步（存檔後其他工具依陣列讀取也一致）
        #expect(scene.elements.compactMap { $0["id"] as? String } == ordered.map(\.id))
    }

    @Test func insertingAtTheSamePlaceOnTwoDevicesMergesDeterministically() throws {
        var base = ExcalidrawScene()
        base.insert(Element.rectangle(x: 0, y: 0, width: 1, height: 1))
        base.insert(Element.rectangle(x: 0, y: 0, width: 1, height: 1))
        let ids = base.orderedElements.map(\.id)

        var local = base, remote = base
        let x = Element.rectangle(x: 1, y: 0, width: 1, height: 1)
        let y = Element.rectangle(x: 2, y: 0, width: 1, height: 1)
        local.insert(x, at: 1)
        remote.insert(y, at: 1)
        // 同一處插入：兩邊產生相同的 index，靠 id 決定順序
        #expect(local.element(x.id)?.index == remote.element(y.id)?.index)

        let ab = ExcalidrawScene.merge(local: local, remote: remote).orderedElements.map(\.id)
        let ba = ExcalidrawScene.merge(local: remote, remote: local).orderedElements.map(\.id)
        #expect(ab == ba)
        #expect(ab.count == 4)
        #expect(ab.first == ids[0] && ab.last == ids[1])
        // 寫成檔案後的陣列順序也相同
        let dataAB = try ExcalidrawScene.merge(local: local, remote: remote).elements.compactMap { $0["id"] as? String }
        #expect(dataAB == ab)

        // 合併後還能繼續在重複 index 的元素旁邊插入
        var merged = ExcalidrawScene.merge(local: local, remote: remote)
        merged.insert(Element.rectangle(x: 3, y: 0, width: 1, height: 1), at: 2)
        #expect(merged.liveElements.count == 5)
        let keys = merged.orderedElements.compactMap(\.index)
        #expect(zip(keys, keys.dropFirst()).allSatisfy { !FractionalIndex.less($1, $0) })
    }

    @Test func legacyFilesWithoutIndexKeepArrayOrder() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "type": "excalidraw", "version": 2,
            "elements": [
                ["type": "rectangle", "id": "z", "x": 0, "y": 0, "version": 1],
                ["type": "rectangle", "id": "a", "x": 0, "y": 0, "version": 1],
            ],
        ])
        var scene = try ExcalidrawScene(data: legacy)
        #expect(scene.orderedElements.map(\.id) == ["z", "a"])
        let el = Element.rectangle(x: 0, y: 0, width: 1, height: 1)
        scene.insert(el)
        #expect(scene.orderedElements.map(\.id) == ["z", "a", el.id])
        #expect(scene.element(el.id)?.index == nil) // 不替舊檔案補 index（補了要遞增每個元素的 version）
        #expect(scene.element("z")?.version == 1)
    }

    @Test func newStrokesGetIndexInIndexedScenes() throws {
        var scene = ExcalidrawScene()
        scene.replaceInk(with: [InkRoundTripTests.sampleStroke(), InkRoundTripTests.sampleStroke(offset: 100)])
        let keys = scene.orderedElements.compactMap(\.index)
        #expect(keys.count == 2 && FractionalIndex.less(keys[0], keys[1]))
    }
}
