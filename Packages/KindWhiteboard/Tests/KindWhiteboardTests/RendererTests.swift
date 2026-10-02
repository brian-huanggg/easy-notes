import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import KindWhiteboard

/// 快照：渲染結果與 `Snapshots/<名稱>.png` 比對。
/// - 基準圖不存在，或 `EASYNOTES_SNAPSHOT_RECORD=1`：寫入基準圖（之後檢查一次再 commit）
/// - `EASYNOTES_SNAPSHOT_DIR=<資料夾>`：把這次的輸出寫到該資料夾，方便與基準圖、excalidraw.com 並排比較
enum Snapshot {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Snapshots")

    static func assertMatches(_ image: CGImage, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let png = try #require(SceneRenderer.png(image))
        let env = ProcessInfo.processInfo.environment
        if let dir = env["EASYNOTES_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(filePath: dir).appending(path: "\(name).png"))
        }
        let baselineURL = directory.appending(path: "\(name).png")
        guard env["EASYNOTES_SNAPSHOT_RECORD"] != "1", let baselineData = try? Data(contentsOf: baselineURL) else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: baselineURL)
            Issue.record("已寫入基準圖 \(baselineURL.path)；確認畫面正確後再執行一次", sourceLocation: sourceLocation)
            return
        }
        let baseline = try #require(CGImageSourceCreateWithData(baselineData as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(baseline.width == image.width && baseline.height == image.height,
                "尺寸 \(image.width)×\(image.height)，基準圖 \(baseline.width)×\(baseline.height)", sourceLocation: sourceLocation)
        guard baseline.width == image.width, baseline.height == image.height else { return }
        // 容許字型抗鋸齒等微小差異：通道差 > 48 的像素不超過 0.5%
        let a = rgba(image), b = rgba(baseline)
        var differing = 0
        for i in stride(from: 0, to: a.count, by: 4) where (0..<4).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 48 }) {
            differing += 1
        }
        let ratio = Double(differing) / Double(image.width * image.height)
        #expect(ratio <= 0.005, "\(name)：\(differing) 個像素不同（\(String(format: "%.2f", ratio * 100))%）",
                sourceLocation: sourceLocation)
    }

    /// 兩張同尺寸的圖相似：通道差 > 48 的像素不超過 `tolerance`。不同時兩張都寫到 `EASYNOTES_SNAPSHOT_DIR`
    static func assertSimilar(_ image: CGImage, to reference: CGImage, named name: String, tolerance: Double,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        try #require(image.width == reference.width && image.height == reference.height, sourceLocation: sourceLocation)
        let a = rgba(image), b = rgba(reference)
        var differing = 0
        for i in stride(from: 0, to: a.count, by: 4) where (0..<4).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 48 }) {
            differing += 1
        }
        let ratio = Double(differing) / Double(image.width * image.height)
        if let dir = ProcessInfo.processInfo.environment["EASYNOTES_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png(image).write(to: URL(filePath: dir).appending(path: "\(name).png"))
            try png(reference).write(to: URL(filePath: dir).appending(path: "\(name)-reference.png"))
        }
        #expect(ratio <= tolerance, "\(name)：\(differing) 個像素不同（\(String(format: "%.2f", ratio * 100))%）",
                sourceLocation: sourceLocation)
    }

    private static func png(_ image: CGImage) throws -> Data {
        try #require(SceneRenderer.png(image))
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }
}

@Suite struct RendererTests {
    // MARK: 快照

    @Test func fixtureSnapshot() throws {
        let scene = try ExcalidrawScene(data: Fixture.data())
        let image = try #require(SceneRenderer(scene: scene).makeImage(maxScale: 1))
        try Snapshot.assertMatches(image, named: "fixture")
    }

    /// 各種箭頭頭部、線條樣式、圓角、旋轉、透明度、曲線、文字對齊、手寫與圖片翻轉
    @Test func stylesSnapshot() throws {
        let image = try #require(SceneRenderer(scene: Self.stylesScene()).makeImage(maxScale: 1))
        try Snapshot.assertMatches(image, named: "styles")
    }

    // MARK: 範圍

    @Test func emptySceneHasNoImage() {
        let renderer = SceneRenderer(scene: ExcalidrawScene())
        #expect(renderer.contentBounds == nil)
        #expect(renderer.makeImage() == nil)
    }

    @Test func boundsIncludeRotationStrokeAndDeletedAreSkipped() throws {
        var scene = ExcalidrawScene()
        var rect = Element.rectangle(x: 0, y: 0, width: 100, height: 20)
        rect.angle = .pi / 2
        scene.insert(rect)
        var gone = Element.rectangle(x: 1000, y: 1000, width: 10, height: 10)
        gone.isDeleted = true
        scene.insert(gone)
        let bounds = try #require(SceneRenderer(scene: scene).contentBounds)
        // 旋轉 90° 後變成 20 寬、100 高，中心不變 (50, 10)；外擴半個線寬 + 1
        #expect(abs(bounds.midX - 50) < 0.01 && abs(bounds.midY - 10) < 0.01)
        #expect(abs(bounds.width - 24) < 0.01 && abs(bounds.height - 104) < 0.01)
    }

    @Test func linearBoxUsesPointsLeftOfOrigin() {
        var line = Element.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 40, y: 160))
        line.raw["endArrowhead"] = NSNull()
        #expect(ElementGeometry.box(line) == CGRect(x: 40, y: 100, width: 60, height: 60))
    }

    @Test func frameBoundsIncludeTitle() {
        let frame = Element.frame(x: 0, y: 100, width: 200, height: 100, name: "A")
        #expect(ElementGeometry.bounds(frame).minY < 100 - ElementGeometry.frameTitleSize)
    }

    @Test func viewportSkipsElementsOutside() throws {
        var scene = ExcalidrawScene()
        var far = Element.rectangle(x: 5000, y: 5000, width: 100, height: 100)
        far.raw["backgroundColor"] = "#ff0000"
        scene.insert(far)
        let renderer = SceneRenderer(scene: scene)
        let ctx = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: -5050, y: -5050)
        renderer.draw(in: ctx, visible: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(Snapshot.rgba(try #require(ctx.makeImage())).allSatisfy { $0 == 0 })
        renderer.draw(in: ctx, visible: nil)
        #expect(Snapshot.rgba(try #require(ctx.makeImage()))[0] > 200)
    }

    // MARK: 顏色

    @Test func parsesExcalidrawColors() {
        #expect(SceneColor.parse("transparent") == nil)
        #expect(SceneColor.parse("#ffffff00") == nil)
        #expect(SceneColor.parse("#f00")?.components == [1, 0, 0, 1])
        #expect(SceneColor.parse("#1971c2")?.components?.count == 4)
        #expect(SceneColor.parse("#00000080")?.alpha.isApproximately(128.0 / 255) == true)
        #expect(SceneColor.parse("bogus") == nil)
    }

    // MARK: 預覽

    @Test func boardPreviewHasTransparentPNGAndTexts() throws {
        let preview = BoardPreview().makePreview(try Fixture.data())
        let png = try #require(preview.image)
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(max(image.width, image.height) <= BoardPreview.maxPixelSize)
        #expect(Snapshot.rgba(image)[3] == 0) // 左上角是透明的（白色背景不畫）
        #expect(preview.lines == ["光合作用 發生在葉綠體"])
        // 同樣的內容產生同樣的 PNG：刪掉快取後重新產生，畫面相同
        #expect(BoardPreview().makePreview(try Fixture.data()).image == png)
    }

    @Test func customBackgroundIsKept() throws {
        var scene = ExcalidrawScene()
        scene.raw["appState"] = ["viewBackgroundColor": "#fff9db"]
        scene.insert(Element.rectangle(x: 0, y: 0, width: 50, height: 50))
        #expect(SceneRenderer(scene: scene, transparentDefaultBackground: true).background != nil)
        scene.raw["appState"] = ["viewBackgroundColor": "#ffffff"]
        #expect(SceneRenderer(scene: scene, transparentDefaultBackground: true).background == nil)
        #expect(SceneRenderer(scene: scene).background != nil)
    }

    @Test func emptyOrInvalidBoardHasNoImage() {
        #expect(BoardPreview().makePreview(InkKind.template(title: "x")).image == nil)
        #expect(BoardPreview().makePreview(Data("nope".utf8)).image == nil)
    }

    // MARK: 效能

    /// 縮圖不在主執行緒產生（測試本身在背景執行），1,000 個元素 < 200 ms（Release、M 系列 Mac）
    @Test func thousandElementsRenderQuickly() throws {
        let scene = Self.randomScene(count: 1000)
        let clock = ContinuousClock()
        var png: Data?
        let elapsed = clock.measure { png = SceneRenderer(scene: scene).pngData() }
        #expect(png != nil)
        #if DEBUG
        let limit: Duration = .milliseconds(600) // Debug build 沒有最佳化，只防止明顯退步
        #else
        let limit: Duration = .milliseconds(200)
        #endif
        print("1,000 個元素：\(elapsed)")
        #expect(elapsed < limit, "1,000 個元素花了 \(elapsed)")
    }

    // MARK: 場景

    static func stylesScene() -> ExcalidrawScene {
        var scene = ExcalidrawScene()
        let heads = ["arrow", "bar", "dot", "circle_outline", "triangle", "triangle_outline", "diamond", "diamond_outline",
                     "crowfoot_one", "crowfoot_many", "crowfoot_one_or_many"]
        for (i, head) in heads.enumerated() {
            var a = Element.arrow(from: CGPoint(x: 20, y: 20 + Double(i) * 30), to: CGPoint(x: 160, y: 20 + Double(i) * 30))
            a.raw["endArrowhead"] = head
            a.raw["startArrowhead"] = i == 0 ? "dot" : NSNull()
            scene.insert(a)
        }
        for (i, style) in ["solid", "dashed", "dotted"].enumerated() {
            var r = Element.rectangle(x: 220 + Double(i) * 130, y: 20, width: 110, height: 70)
            r.raw["strokeStyle"] = style
            r.raw["strokeWidth"] = [1, 2, 4][i]
            r.raw["backgroundColor"] = ["#ffc9c9", "#b2f2bb", "transparent"][i]
            scene.insert(r)
        }
        var sharp = Element.rectangle(x: 220, y: 120, width: 110, height: 70)
        sharp.raw["roundness"] = NSNull()
        sharp.angle = .pi / 8
        scene.insert(sharp)
        var faded = Element.ellipse(x: 350, y: 120, width: 110, height: 70)
        faded.raw["backgroundColor"] = "#1971c2"
        faded.raw["opacity"] = 40
        scene.insert(faded)
        var diamond = Element.ellipse(x: 480, y: 120, width: 110, height: 70)
        diamond.raw["type"] = "diamond"
        diamond.raw["roundness"] = ["type": 2]
        diamond.raw["strokeColor"] = "#e03131"
        scene.insert(diamond)

        var curve = Element.arrow(from: CGPoint(x: 220, y: 240), to: CGPoint(x: 600, y: 240))
        curve.setAbsolutePoints([CGPoint(x: 220, y: 240), CGPoint(x: 320, y: 200), CGPoint(x: 420, y: 280), CGPoint(x: 600, y: 230)])
        curve.raw["strokeColor"] = "#2f9e44"
        scene.insert(curve)
        var polygon = Element.arrow(from: .zero, to: .zero)
        polygon.raw["type"] = "line"
        polygon.raw["endArrowhead"] = NSNull()
        polygon.raw["roundness"] = NSNull()
        polygon.raw["backgroundColor"] = "#ffec99"
        polygon.setAbsolutePoints([CGPoint(x: 220, y: 300), CGPoint(x: 300, y: 380), CGPoint(x: 220, y: 380), CGPoint(x: 220, y: 300)])
        scene.insert(polygon)

        for (i, align) in ["left", "center", "right"].enumerated() {
            var t = Element.text("對齊 \(align)\n第二行比較長一點", x: 340, y: 300 + Double(i) * 60, fontSize: 16)
            t.raw["textAlign"] = align
            t.width = 220
            scene.insert(t)
        }

        // 手寫：perfect-freehand 寬度（有壓力）與 PencilKit 筆畫（customData 的點大小）
        var free = Element.arrow(from: .zero, to: .zero)
        free.raw["type"] = "freedraw"
        free.raw["endArrowhead"] = NSNull()
        free.setAbsolutePoints((0..<40).map { CGPoint(x: 20 + Double($0) * 4, y: 380 + sin(Double($0) / 4) * 20) })
        free.raw["pressures"] = (0..<40).map { Double($0) / 40 }
        free.raw["simulatePressure"] = false
        free.raw["strokeWidth"] = 1
        scene.insert(free)
        scene.replaceInk(with: scene.inkStrokes + [InkStroke(
            ink: "com.apple.ink.pen", color: "#1971c2",
            points: (0..<30).map { InkStroke.Point(x: 20 + Double($0) * 5, y: 440 + cos(Double($0) / 3) * 10, size: 2 + Double($0) / 6) })])

        // 圖片：水平翻轉、圓角
        let imageID = scene.insertImage(Fixture.pngData(width: 120, height: 60), at: CGPoint(x: 620, y: 300), maxDisplay: 120)!
        scene.mutate(imageID) {
            $0.raw["scale"] = [-1, 1]
            $0.raw["roundness"] = ["type": 3]
        }
        return scene
    }

    /// 固定種子的 1,000 個元素：形狀、箭頭、文字、手寫混合
    static func randomScene(count: Int) -> ExcalidrawScene {
        var rng = SeededGenerator(seed: 42)
        var elements: [[String: Any]] = []
        for i in 0..<count {
            let x = Double.random(in: 0..<4000, using: &rng), y = Double.random(in: 0..<3000, using: &rng)
            var el: Element
            switch i % 5 {
            case 0: el = .rectangle(x: x, y: y, width: 120, height: 80); el.raw["backgroundColor"] = "#a5d8ff"
            case 1: el = .ellipse(x: x, y: y, width: 100, height: 60)
            case 2: el = .arrow(from: CGPoint(x: x, y: y), to: CGPoint(x: x + 120, y: y + 40))
            case 3: el = .text("文字 \(i) text", x: x, y: y)
            default:
                el = .arrow(from: .zero, to: .zero)
                el.raw["type"] = "freedraw"
                el.setAbsolutePoints((0..<30).map { CGPoint(x: x + Double($0) * 3, y: y + sin(Double($0)) * 8) })
            }
            el.angle = i % 7 == 0 ? 0.3 : 0
            elements.append(el.raw)
        }
        var scene = ExcalidrawScene()
        scene.raw["elements"] = elements
        return scene
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension CGFloat {
    func isApproximately(_ other: Double) -> Bool { abs(Double(self) - other) < 0.01 }
}
