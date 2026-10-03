import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import ExcalidrawKit
@testable import KindWhiteboard

@MainActor
struct LayerTreeTests {
    /// 一排 n 個矩形，每個 100×100、間隔 200
    private func row(_ n: Int) -> ExcalidrawScene {
        var scene = ExcalidrawScene()
        for i in 0..<n { scene.insert(Element.rectangle(x: Double(i) * 200, y: 0, width: 100, height: 100)) }
        return scene
    }

    private func ids(_ tree: BoardLayerTree) -> [String] {
        (tree.root.sublayers ?? []).compactMap { ($0 as? ElementLayer)?.elementID }
    }

    @Test func onlyVisibleElementsGetLayers() {
        let scene = row(10)
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.setScene(scene)
        #expect(tree.layerCount == 0) // 還沒有可見範圍
        tree.updateVisible(CGRect(x: -10, y: -10, width: 520, height: 120))
        #expect(tree.layerCount == 3) // x = 0, 200, 400
        tree.updateVisible(CGRect(x: 1390, y: -10, width: 300, height: 120))
        #expect(tree.layerCount == 2) // x = 1400, 1600；先前的被移除
    }

    @Test func creationIsBatched() {
        let scene = row(300)
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.setScene(scene)
        let everything = CGRect(x: -100, y: -100, width: 70_000, height: 400)
        #expect(tree.updateVisible(everything, budget: 120))
        #expect(tree.layerCount == 120)
        #expect(tree.updateVisible(everything, budget: 120))
        #expect(!tree.updateVisible(everything, budget: 120))
        #expect(tree.layerCount == 300)
        #expect(ids(tree) == scene.liveElements.map(\.id))
    }

    @Test func layersFollowElementOrderWhenCreatedOutOfOrder() {
        let scene = row(5)
        let order = scene.liveElements.map(\.id)
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.setScene(scene)
        // 先看到右邊，再看到左邊：插入時要依元素順序，不是建立順序
        tree.updateVisible(CGRect(x: 590, y: 0, width: 300, height: 100))
        tree.updateVisible(CGRect(x: -10, y: 0, width: 1000, height: 100))
        #expect(ids(tree) == order)
    }

    @Test func onlyChangedElementsAreRebuilt() throws {
        var scene = row(3)
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.setScene(scene)
        tree.updateVisible(CGRect(x: -10, y: -10, width: 1000, height: 200))
        let ids = scene.liveElements.map(\.id)
        let before = ids.map { tree.layer(for: $0) }

        scene.move([ids[1]], dx: 0, dy: 30)
        tree.setScene(scene)
        let after = ids.map { tree.layer(for: $0) }
        #expect(after[0] === before[0])
        #expect(after[2] === before[2])
        #expect(after[1] !== before[1])
        let moved = try #require(after[1])
        #expect(abs(moved.frame.minY - (30 - 2)) < 0.01) // 外擴 = 線寬一半 + 1
        #expect(self.ids(tree) == ids)
    }

    @Test func deletedAndReorderedElements() {
        var scene = row(3)
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.setScene(scene)
        tree.updateVisible(CGRect(x: -10, y: -10, width: 1000, height: 200))
        let ids = scene.liveElements.map(\.id)

        scene.delete([ids[0]])
        tree.setScene(scene)
        #expect(self.ids(tree) == [ids[1], ids[2]])

        // 外部合併帶來新元素，插在最前面（舊檔案沒有 index，依陣列順序）
        let extra = Element.rectangle(x: 50, y: 0, width: 100, height: 100)
        scene.raw["elements"] = [extra.raw] + scene.elements
        tree.setScene(scene)
        #expect(self.ids(tree) == [extra.id, ids[1], ids[2]])
    }

    @Test func freedrawSkippedWhenPencilKitDrawsIt() {
        var scene = row(1)
        scene.replaceInk(with: [InkStroke(ink: "com.apple.ink.pen", color: "#000000", opacity: 1, points: [
            .init(x: 10, y: 10, force: 1, size: 2, timeOffset: 0, azimuth: 0, altitude: 1, opacity: 1),
            .init(x: 50, y: 50, force: 1, size: 2, timeOffset: 0.1, azimuth: 0, altitude: 1, opacity: 1),
        ])])
        let rect = CGRect(x: -10, y: -10, width: 200, height: 200)
        let ios = BoardLayerTree(drawsFreedraw: false)
        ios.setScene(scene)
        ios.updateVisible(rect)
        #expect(ios.layerCount == 1)
        let mac = BoardLayerTree(drawsFreedraw: true)
        mac.setScene(scene)
        mac.updateVisible(rect)
        #expect(mac.layerCount == 2)
    }

    @Test func hiddenElements() throws {
        let scene = row(2)
        let id = scene.liveElements[0].id
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.hiddenIDs = [id]
        tree.setScene(scene)
        tree.updateVisible(CGRect(x: -10, y: -10, width: 1000, height: 200))
        #expect(try #require(tree.layer(for: id)).isHidden)
        tree.hiddenIDs = []
        #expect(try #require(tree.layer(for: id)).isHidden == false)
    }

    @Test func rasterRescaleIsBatched() {
        var scene = ExcalidrawScene()
        for i in 0..<5 { scene.insert(Element.text("文字 \(i)", x: Double(i) * 200, y: 0)) }
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.setScene(scene)
        tree.updateVisible(CGRect(x: -10, y: -10, width: 2000, height: 200))
        tree.setContentsScale(4)
        #expect(tree.hasPendingWork)
        #expect(tree.drainRaster(budget: 3))
        #expect(!tree.drainRaster(budget: 3))
        for el in scene.liveElements {
            #expect(tree.layer(for: el.id)?.sublayers?.first?.contentsScale == 4)
        }
        // 縮放途中：只會降低，不重畫既有的
        tree.setContentsScale(8, immediate: false)
        #expect(tree.contentsScale == 4)
        tree.setContentsScale(1, immediate: false)
        #expect(tree.contentsScale == 1)
        #expect(!tree.hasPendingWork)
    }

    /// layer 樹畫出來要與 `SceneRenderer` 相同（同一份幾何與 painter）
    @Test(arguments: ["fixture", "styles"])
    func matchesSceneRenderer(_ name: String) throws {
        let scene = name == "styles" ? RendererTests.stylesScene() : try ExcalidrawScene(data: Fixture.data())
        let renderer = SceneRenderer(scene: scene)
        let area = try #require(renderer.contentBounds).insetBy(dx: -16, dy: -16)
        let scale: CGFloat = 1
        let width = Int(area.width * scale), height = Int(area.height * scale)

        func context() throws -> CGContext {
            let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(SceneColor.rgb(0xffffff))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -area.minX, y: -area.minY)
            return ctx
        }

        let expected = try context()
        renderer.draw(in: expected, visible: area, pixelScale: scale)

        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.setContentsScale(scale)
        tree.setScene(scene)
        tree.updateVisible(area, budget: .max)
        tree.root.isGeometryFlipped = true // render(in:) 依 macOS 慣例 y 向上；與 iOS / 翻轉的 NSView 一致
        let actual = try context()
        tree.root.render(in: actual)

        let a = try #require(expected.makeImage()), b = try #require(actual.makeImage())
        try Snapshot.assertSimilar(b, to: a, named: "layer-tree-\(name)", tolerance: 0.02)
    }
}
