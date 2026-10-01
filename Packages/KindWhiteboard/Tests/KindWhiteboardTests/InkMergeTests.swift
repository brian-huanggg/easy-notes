import Foundation
import Testing
import EasyNotesCore
@testable import KindWhiteboard

/// Phase 2：.excalidraw 依元素 id + version 合併
struct InkMergeTests {
    func scene(_ strokes: [InkStroke]) -> ExcalidrawScene {
        var scene = ExcalidrawScene()
        scene.replaceInk(with: strokes)
        return scene
    }

    @Test func bothSidesAddStrokes() throws {
        let base = scene([InkRoundTripTests.sampleStroke()])
        var local = base, remote = base
        local.replaceInk(with: base.inkStrokes + [InkRoundTripTests.sampleStroke(offset: 100)])
        remote.replaceInk(with: base.inkStrokes + [InkRoundTripTests.sampleStroke(offset: 200)])

        let data = try #require(InkKind.merge(base: base.data(), local: local.data(), remote: remote.data()))
        let merged = try ExcalidrawScene(data: data)
        #expect(merged.inkStrokes.count == 3)
    }

    @Test func higherVersionWinsForSameElement() throws {
        let base = scene([InkRoundTripTests.sampleStroke(), InkRoundTripTests.sampleStroke(offset: 50)])
        // 遠端刪掉第一筆（墓碑 version 2），本地沒動
        var remote = base
        remote.replaceInk(with: [base.inkStrokes[1]])

        let merged = ExcalidrawScene.merge(local: base, remote: remote)
        #expect(merged.inkStrokes.count == 1)
        #expect(merged.elements.count == 2)
        // 反過來合併結果相同
        #expect(ExcalidrawScene.merge(local: remote, remote: base).inkStrokes.count == 1)
    }

    @Test func invalidJSONBecomesConflict() throws {
        let valid = try scene([]).data()
        #expect(InkKind.merge(base: nil, local: valid, remote: Data("not json".utf8)) == nil)
    }
}
