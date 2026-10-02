import CoreGraphics
import Foundation
import Testing
@testable import KindWhiteboard

/// 4c：LOD（縮很小又有很多元素時改畫點陣快照）
@MainActor
struct LODTests {
    /// 直接組 elements 陣列（逐個 `insert` 要幾毫秒，1,600 個會拖慢測試）
    private func grid(_ n: Int) -> ExcalidrawScene {
        var scene = ExcalidrawScene()
        scene.raw["elements"] = (0..<n).map { i -> [String: Any] in
            var el = Element.rectangle(x: Double(i % 50) * 120, y: Double(i / 50) * 120, width: 100, height: 100)
            el.raw["backgroundColor"] = "#ffc9c9"
            return el.raw
        }
        return scene
    }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func thresholds() {
        #expect(BoardLOD.shouldUse(count: 2_000, zoom: 0.3, idle: true))
        #expect(!BoardLOD.shouldUse(count: 2_000, zoom: 0.5, idle: true)) // 還不夠小
        #expect(!BoardLOD.shouldUse(count: 1_000, zoom: 0.3, idle: true)) // 元素不夠多
        #expect(!BoardLOD.shouldUse(count: 2_000, zoom: 0.3, idle: false)) // 有選取 / 操作中
    }

    @Test func pixelScaleIsCappedByMaxPixels() {
        let big = CGRect(x: 0, y: 0, width: 40_000, height: 20_000)
        let scale = BoardLOD.pixelScale(rect: big, zoom: 0.25, screenScale: 2)
        #expect(scale <= BoardLOD.maxPixels / 40_000 + 1e-9)
        #expect(BoardLOD.pixelScale(rect: CGRect(x: 0, y: 0, width: 1000, height: 1000), zoom: 0.25, screenScale: 2) == 0.5)
    }

    @Test func snapshotIsUprightAndTransparentElsewhere() throws {
        var scene = ExcalidrawScene()
        var el = Element.rectangle(x: 0, y: 0, width: 50, height: 50) // 左上角
        el.raw["backgroundColor"] = "#ff0000"
        el.raw["strokeColor"] = "#ff0000"
        scene.insert(el)
        let renderer = SceneRenderer(scene: scene)
        let image = try #require(BoardLOD.render(renderer, rect: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1,
                                                 drawsFreedraw: true))
        #expect(image.width == 100 && image.height == 100)
        let data = try #require(image.dataProvider?.data as Data?)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * image.bytesPerRow + x * 4 + 3] }
        func red(_ x: Int, _ y: Int) -> UInt8 { data[y * image.bytesPerRow + x * 4] }
        #expect(alpha(25, 25) == 255 && red(25, 25) == 255) // 影像上方
        #expect(alpha(75, 75) == 0) // 影像下方沒有東西
    }

    @Test func freedrawCanBeExcluded() throws {
        var scene = ExcalidrawScene()
        var free = Element.arrow(from: .zero, to: .zero)
        free.raw["type"] = "freedraw"
        free.raw["endArrowhead"] = NSNull()
        free.setAbsolutePoints((0..<10).map { CGPoint(x: Double($0) * 5, y: 20) })
        free.raw["strokeWidth"] = 2
        scene.insert(free)
        let renderer = SceneRenderer(scene: scene)
        let rect = CGRect(x: -10, y: 0, width: 80, height: 40)
        func covered(_ image: CGImage?) -> Bool {
            guard let image, let data = image.dataProvider?.data as Data? else { return false }
            return (0..<image.height).contains { y in (0..<image.width).contains { x in data[y * image.bytesPerRow + x * 4 + 3] > 0 } }
        }
        #expect(covered(BoardLOD.render(renderer, rect: rect, scale: 1, drawsFreedraw: true)))
        #expect(!covered(BoardLOD.render(renderer, rect: rect, scale: 1, drawsFreedraw: false)))
    }

    @Test func treeInLODDropsAndSkipsLayers() {
        let scene = grid(200)
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.setScene(scene)
        let all = CGRect(x: -10, y: -10, width: 7_000, height: 600)
        tree.updateVisible(all, budget: 1_000)
        #expect(tree.layerCount == 200)
        #expect(tree.visibleCount(in: all) == 200)
        tree.lodActive = true
        #expect(tree.layerCount == 0)
        tree.updateVisible(all, budget: 1_000)
        #expect(tree.layerCount == 0)
        tree.lodActive = false // 關閉時依最近的可見範圍重建
        #expect(tree.layerCount == 120) // 分批
    }

    @Test func activatesWhenSmallAndCrowdedThenDeactivates() async throws {
        let scene = grid(1_600)
        let tree = BoardLayerTree(drawsFreedraw: false)
        tree.setScene(scene)
        let lod = BoardLOD(tree: tree, drawsFreedraw: false) { scene }
        let visible = CGRect(x: 0, y: 0, width: 6_000, height: 4_000) // 約 1,600 個都在範圍內
        tree.updateVisible(visible, budget: 5_000)

        lod.viewChanged(visible: visible, zoom: 0.3, screenScale: 2, idle: false)
        #expect(!lod.isActive) // 有選取：不啟用

        lod.viewChanged(visible: visible, zoom: 0.3, screenScale: 2, idle: true)
        await waitUntil { lod.isActive }
        #expect(lod.isActive)
        #expect(tree.lodActive && tree.layerCount == 0)
        #expect(!lod.root.isHidden && lod.root.image != nil)

        lod.viewChanged(visible: visible, zoom: 1, screenScale: 2, idle: true) // 放大回來
        #expect(!lod.isActive && !tree.lodActive && lod.root.isHidden)
        #expect(tree.layerCount > 0)
    }

    @Test func selectionWhileActiveFallsBackToLayers() async throws {
        let scene = grid(1_600)
        let tree = BoardLayerTree(drawsFreedraw: false)
        tree.setScene(scene)
        let lod = BoardLOD(tree: tree, drawsFreedraw: false) { scene }
        let visible = CGRect(x: 0, y: 0, width: 6_000, height: 4_000)
        tree.updateVisible(visible, budget: 5_000)
        lod.viewChanged(visible: visible, zoom: 0.3, screenScale: 2, idle: true)
        await waitUntil { lod.isActive }
        lod.viewChanged(visible: visible, zoom: 0.3, screenScale: 2, idle: false) // 選了元素
        #expect(!lod.isActive && !tree.lodActive)
    }
}
