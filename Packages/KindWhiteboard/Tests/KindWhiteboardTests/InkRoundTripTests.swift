import Foundation
import Testing
import EasyNotesCore
@testable import ExcalidrawKit
@testable import KindWhiteboard

#if canImport(PencilKit)
import PencilKit
#endif

/// Spike S2：PencilKit 筆畫 ⇄ Excalidraw freedraw 來回轉換
struct InkRoundTripTests {
    static func sampleStroke(offset: Double = 0) -> InkStroke {
        let points = (0..<50).map { (i: Int) -> InkStroke.Point in
            let t = Double(i)
            let x: Double = 100 + offset + t * 3
            let y: Double = 200 + sin(t / 5) * 20
            let force: Double = 0.5 + Double(i % 10) / 5
            return InkStroke.Point(x: x, y: y, force: force, size: 3.5, timeOffset: t / 240, azimuth: 0.8, altitude: 1.1)
        }
        return InkStroke(ink: "com.apple.ink.pen", color: "#1e1e1e", points: points)
    }

    /// excalidraw.com 的筆畫沒有點大小：粗細與渲染器相同（perfect-freehand，strokeWidth × 4.25），不是 strokeWidth
    @Test func foreignFreedrawUsesRendererWidths() throws {
        let scene = try ExcalidrawScene(data: Fixture.data())
        let raw = try #require(scene.elements.first { $0["type"] as? String == "freedraw" })
        let stroke = try #require(ExcalidrawScene.decode(raw))
        let widths = ElementGeometry.freedrawWidths(Element(raw: raw))
        #expect(stroke.points.map(\.size) == widths)
        #expect((widths.min() ?? 0) > 2)
    }

    @Test func freedrawRoundTripPreservesPointsAndPressure() throws {
        var scene = ExcalidrawScene()
        scene.replaceInk(with: [Self.sampleStroke()])
        let reloaded = try ExcalidrawScene(data: scene.data())

        let stroke = try #require(reloaded.inkStrokes.first)
        #expect(stroke.points.count == 50)
        #expect(stroke.matches(Self.sampleStroke(), tolerance: 1e-9))
        #expect(stroke.points[7].timeOffset == Self.sampleStroke().points[7].timeOffset)
    }

    @Test func outputIsValidExcalidrawFreedraw() throws {
        var scene = ExcalidrawScene()
        scene.replaceInk(with: [Self.sampleStroke()])
        let json = try #require(JSONSerialization.jsonObject(with: scene.data()) as? [String: Any])
        #expect(json["type"] as? String == "excalidraw")

        let el = try #require((json["elements"] as? [[String: Any]])?.first)
        #expect(el["type"] as? String == "freedraw")
        let points = try #require(el["points"] as? [[Double]])
        let pressures = try #require(el["pressures"] as? [Double])
        #expect(points.count == pressures.count)
        // Excalidraw 規定 points 相對於元素原點，且 pressure 在 0...1
        #expect(points.allSatisfy { $0[0] >= 0 && $0[1] >= 0 })
        #expect(pressures.allSatisfy { (0...1).contains($0) })
    }

    @Test func unchangedStrokesKeepTheirElementAndOthersArePreserved() throws {
        let rect: [String: Any] = ["type": "rectangle", "id": "rect-1", "x": 0, "y": 0, "version": 3, "unknownField": "keep me"]
        var scene = try ExcalidrawScene(data: JSONSerialization.data(withJSONObject: [
            "type": "excalidraw", "version": 2, "elements": [rect],
        ]))
        scene.replaceInk(with: [Self.sampleStroke(), Self.sampleStroke(offset: 500)])
        let firstIDs = scene.inkStrokes.compactMap(\.id)

        // 刪掉第二筆、保留第一筆
        scene.replaceInk(with: [Self.sampleStroke()])

        let els = scene.elements
        #expect(els.first?["unknownField"] as? String == "keep me")
        #expect(scene.inkStrokes.compactMap(\.id) == [firstIDs[0]])
        let tomb = try #require(els.first { $0["id"] as? String == firstIDs[1] })
        #expect(tomb["isDeleted"] as? Bool == true)
        #expect(tomb["version"] as? Int == 2)
    }

    @Test func foreignFreedrawWithoutCustomDataDecodes() throws {
        // excalidraw.com 畫的筆畫：沒有 customData、使用 simulatePressure
        let el: [String: Any] = [
            "type": "freedraw", "id": "abc", "x": 10, "y": 20, "strokeColor": "#e03131", "strokeWidth": 2,
            "opacity": 100, "points": [[0, 0], [5, 5], [10, 3]], "pressures": [], "simulatePressure": true,
        ]
        let scene = try ExcalidrawScene(data: JSONSerialization.data(withJSONObject: [
            "type": "excalidraw", "version": 2, "elements": [el],
        ]))
        let stroke = try #require(scene.inkStrokes.first)
        #expect(stroke.points.map(\.x) == [10, 15, 20])
        #expect(stroke.color == "#e03131")
    }

    #if canImport(PencilKit)
    @Test func pencilKitRoundTrip() throws {
        let original = Self.sampleStroke()
        let drawing = PKDrawing(strokes: [original.pkStroke])

        var scene = ExcalidrawScene()
        scene.update(from: drawing)
        let restored = try ExcalidrawScene(data: scene.data()).drawing

        let back = try #require(restored.strokes.first.map(InkStroke.init))
        #expect(back.points.count == original.points.count)
        #expect(back.matches(original))
        #expect(back.ink == "com.apple.ink.pen")

        // 再存一次不應產生任何變更（同步不會誤判）
        let before = try scene.data()
        scene.update(from: restored)
        #expect(try scene.data() == before)
    }
    #endif
}
