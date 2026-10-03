import CoreGraphics
import Foundation
import Testing
import EasyNotesCore
@testable import ExcalidrawKit
@testable import KindWhiteboard

/// 4a：箭頭綁定、文字、frame、圖片、連結
struct ModelEditingTests {
    // MARK: 綁定

    @Test func bindingPlacesEndpointsOnOutlinePlusGap() throws {
        let (scene, r, e, a) = Fixture.boundScene()
        let arrow = try #require(scene.element(a))
        let pts = arrow.absolutePoints
        #expect(abs(pts[0].x - 305) < 1e-6 && abs(pts[0].y - 150) < 1e-6)
        #expect(abs(pts[1].x - 495) < 1e-6 && abs(pts[1].y - 150) < 1e-6)
        #expect(arrow.binding(.start)?.elementId == r)
        #expect(arrow.binding(.end)?.elementId == e)
        #expect(arrow.binding(.start)?.fixedPoint != nil)
        #expect(Fixture.bindingProblems(scene).isEmpty)
    }

    @Test func movingShapeKeepsArrowAtGapFromOutline() throws {
        var (scene, r, _, a) = Fixture.boundScene()
        let before = try #require(scene.element(a)).version

        scene.move([r], dx: 0, dy: 100) // 斜向
        let rect = try #require(scene.element(r)).rect
        let start = try #require(scene.element(a)?.absolutePoints.first)
        #expect(abs(Fixture.distance(from: start, to: rect) - 5) < 1e-6)
        #expect(try #require(scene.element(a)).version > before)

        scene.move([r], dx: -50, dy: -100) // 回到水平
        let p = try #require(scene.element(a)?.absolutePoints.first)
        #expect(abs(p.x - 255) < 1e-6 && abs(p.y - 150) < 1e-6)
        #expect(Fixture.bindingProblems(scene).isEmpty)
    }

    @Test func resizingShapeMovesBoundEndpoint() throws {
        var (scene, r, _, a) = Fixture.boundScene()
        scene.resize(r, to: CGRect(x: 100, y: 100, width: 300, height: 100))
        let p = try #require(scene.element(a)?.absolutePoints.first)
        #expect(abs(p.x - 405) < 1e-6 && abs(p.y - 150) < 1e-6)
    }

    @Test func unrelatedMoveDoesNotTouchArrow() throws {
        var (scene, _, _, a) = Fixture.boundScene()
        let other = Element.rectangle(x: 0, y: 500, width: 10, height: 10)
        scene.insert(other)
        let before = try #require(scene.element(a)).raw
        scene.move([other.id], dx: 10, dy: 10)
        #expect(NSDictionary(dictionary: before).isEqual(to: try #require(scene.element(a)).raw))
    }

    @Test func deletingShapeClearsArrowBinding() throws {
        var (scene, r, e, a) = Fixture.boundScene()
        let textResult = scene.addBoundText("標題", to: r)
        let text = try #require(textResult)
        scene.delete([r])
        let arrow = try #require(scene.element(a))
        #expect(!arrow.isDeleted)
        #expect(arrow.binding(.start) == nil)
        #expect(arrow.binding(.end)?.elementId == e)
        #expect(scene.element(text)?.isDeleted == true) // 形狀內的文字一起刪除
        #expect(Fixture.bindingProblems(scene).isEmpty)
    }

    @Test func deletingArrowRemovesItFromBoundElements() throws {
        var (scene, r, e, a) = Fixture.boundScene()
        scene.delete([a])
        #expect(scene.element(r)?.boundElements.isEmpty == true)
        #expect(scene.element(e)?.boundElements.isEmpty == true)
        #expect(Fixture.bindingProblems(scene).isEmpty)
    }

    @Test func movingArrowAloneUnbindsIt() throws {
        var (scene, r, e, a) = Fixture.boundScene()
        scene.move([a], dx: 0, dy: 300)
        #expect(scene.element(a)?.binding(.start) == nil)
        #expect(scene.element(r)?.boundElements.isEmpty == true)
        #expect(scene.element(e)?.boundElements.isEmpty == true)
        // 箭頭與兩個形狀一起移動：綁定保留
        var (s2, r2, e2, a2) = Fixture.boundScene()
        s2.move([a2, r2, e2], dx: 30, dy: 30)
        #expect(s2.element(a2)?.binding(.start)?.elementId == r2)
        let p = try #require(s2.element(a2)?.absolutePoints.first)
        #expect(abs(p.x - 335) < 1e-6 && abs(p.y - 180) < 1e-6)
    }

    @Test func rotatedAndOtherShapesUseTheirOutline() throws {
        let rect = Element.rectangle(x: 100, y: 100, width: 200, height: 100)
        var rotated = rect
        rotated.angle = .pi / 2
        let p = Geometry.point(in: rotated, ratio: CGPoint(x: 1, y: 0.5))
        #expect(abs(p.x - 200) < 1e-9 && abs(p.y - 250) < 1e-9)

        let diamond = Element(raw: Element.rectangle(x: 0, y: 0, width: 100, height: 100).raw.merging(["type": "diamond"]) { $1 })
        let hit = try #require(Geometry.entry(from: CGPoint(x: -100, y: 50), toward: CGPoint(x: 50, y: 50), shape: diamond, gap: 0))
        #expect(abs(hit.x) < 1e-9 && abs(hit.y - 50) < 1e-9)
        // 菱形擴 gap：邊向外平移 5，左頂點移到 x = -5√2
        let g = try #require(Geometry.entry(from: CGPoint(x: -100, y: 50), toward: CGPoint(x: 50, y: 50), shape: diamond, gap: 5))
        #expect(abs(g.x - (-5 * 2.0.squareRoot())) < 1e-9)
    }

    // MARK: 文字

    @Test func boundTextIsCenteredAndWrappedInContainer() throws {
        var scene = ExcalidrawScene()
        let rect = Element.rectangle(x: 0, y: 0, width: 200, height: 100)
        scene.insert(rect)
        let idResult = scene.addBoundText("Hello", to: rect.id)
        let id = try #require(idResult)
        let text = try #require(scene.element(id))
        #expect(text.containerId == rect.id)
        #expect(text.textAlign == "center" && text.verticalAlign == "middle")
        #expect(abs(text.center.x - 100) < 1e-6 && abs(text.center.y - 50) < 1e-6)
        #expect(text.height == 25) // 一行 × 20 × 1.25
        #expect(scene.element(rect.id)?.boundElements.map(\.id) == [id])
        // 文字插在容器正上方
        let order = scene.orderedElements.map(\.id)
        #expect(order.firstIndex(of: id) == order.firstIndex(of: rect.id)! + 1)
        #expect(Fixture.bindingProblems(scene).isEmpty)
    }

    @Test func longCJKTextWrapsAndGrowsContainer() throws {
        var scene = ExcalidrawScene()
        let rect = Element.rectangle(x: 0, y: 0, width: 80, height: 30)
        scene.insert(rect)
        let source = "這是一段很長的中文文字需要換行才放得下"
        let idResult = scene.addBoundText(source, to: rect.id)
        let id = try #require(idResult)
        let text = try #require(scene.element(id))
        let container = try #require(scene.element(rect.id))
        #expect(text.originalText == source)
        #expect(text.text.contains("\n"))
        #expect(text.text.replacingOccurrences(of: "\n", with: "") == source)
        #expect(text.width <= 80 - 10)
        #expect(container.height >= text.height + 10)
        #expect(container.version > rect.version)
    }

    @Test func layoutBreaksCJKAndRespectsWidth() {
        let result = TextLayout.layout("光合作用發生在葉綠體", fontSize: 20, lineHeight: 1.25, maxWidth: 50)
        #expect(result.lines.count > 1)
        #expect(result.size.width <= 50)
        let unwrapped = TextLayout.layout("第一行\n第二行", fontSize: 20, lineHeight: 1.25, maxWidth: nil)
        #expect(unwrapped.lines == ["第一行", "第二行"])
        #expect(unwrapped.size.height == 50)
    }

    @Test func movingContainerMovesText() throws {
        var scene = ExcalidrawScene()
        let rect = Element.rectangle(x: 0, y: 0, width: 200, height: 100)
        scene.insert(rect)
        let idResult = scene.addBoundText("Hi", to: rect.id)
        let id = try #require(idResult)
        let before = try #require(scene.element(id))
        scene.move([rect.id], dx: 40, dy: 20)
        let after = try #require(scene.element(id))
        #expect(after.x == before.x + 40 && after.y == before.y + 20)
    }

    @Test func standaloneTextFitsItsContent() throws {
        var scene = ExcalidrawScene()
        let el = Element.text("a", x: 0, y: 0)
        scene.insert(el)
        scene.setText(el.id, to: "一行\n兩行")
        let t = try #require(scene.element(el.id))
        #expect(t.text == "一行\n兩行")
        #expect(t.height == 50)
    }

    // MARK: frame

    @Test func movingFrameMovesChildrenAndDeletingFrameDeletesThem() throws {
        var scene = ExcalidrawScene()
        let frame = Element.frame(x: 0, y: 0, width: 400, height: 300, name: "A")
        let child = Element.rectangle(x: 10, y: 10, width: 50, height: 50)
        let outside = Element.rectangle(x: 500, y: 0, width: 50, height: 50)
        scene.insert(frame); scene.insert(child); scene.insert(outside)
        scene.setFrame([child.id], to: frame.id)
        #expect(scene.children(ofFrame: frame.id).map(\.id) == [child.id])

        scene.move([frame.id], dx: 100, dy: 0)
        #expect(scene.element(child.id)?.x == 110)
        #expect(scene.element(child.id)?.frameId == frame.id)
        #expect(scene.element(outside.id)?.x == 500)

        scene.delete([frame.id])
        #expect(scene.element(child.id)?.isDeleted == true)
        #expect(scene.element(outside.id)?.isDeleted == false)
    }

    // MARK: 圖片

    @Test func insertedImageIsDownscaledToJPEGAndDeduplicated() throws {
        var scene = ExcalidrawScene()
        let png = Fixture.pngData(width: 3000, height: 1500)
        let idResult = scene.insertImage(png, at: .zero)
        let id = try #require(idResult)
        let el = try #require(scene.element(id))
        let fileId = try #require(el.fileId)
        let file = try #require((scene.raw["files"] as? [String: Any])?[fileId] as? [String: Any])
        #expect(file["mimeType"] as? String == "image/jpeg")
        #expect((file["dataURL"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        let stored = try #require(scene.imageData(fileId: fileId))
        let size = try #require(Fixture.pixelSize(stored))
        #expect(size.0 == 2048 && size.1 == 1024)
        #expect(el.width == 400 && el.height == 200)

        // 同一張圖不重複內嵌；刪除元素不刪 files
        scene.insertImage(png, at: .zero)
        #expect((scene.raw["files"] as? [String: Any])?.count == 1)
        scene.delete([id])
        #expect(scene.imageData(fileId: fileId) != nil)
    }

    @Test func smallImagesAreNotUpscaledAndTransparencyKeepsPNG() throws {
        var scene = ExcalidrawScene()
        let idResult = scene.insertImage(Fixture.pngData(width: 100, height: 50), at: .zero)
        let id = try #require(idResult)
        let smallFile = try #require(scene.element(id)?.fileId)
        let small = try #require(scene.imageData(fileId: smallFile))
        #expect(Fixture.pixelSize(small).map { [$0.0, $0.1] } == [100, 50])

        let alphaIDResult = scene.insertImage(Fixture.pngData(width: 64, height: 64, alpha: true), at: .zero)

        let alphaID = try #require(alphaIDResult)
        let file = (scene.raw["files"] as? [String: Any])?[scene.element(alphaID)!.fileId!] as? [String: Any]
        #expect(file?["mimeType"] as? String == "image/png")
        #expect(scene.insertImage(Data("not an image".utf8), at: .zero) == nil)
    }

    // MARK: 連結與索引

    @Test func indexCollectsNoteLinksAndCountsElements() throws {
        let data = try Fixture.data()
        let entry = InkKind.index(data, fileName: "board.excalidraw")
        #expect(entry.links == ["光合作用"])
        #expect(entry.summary == "13 個元素") // 已刪除的不算
        #expect(entry.plainText.contains("光合作用"))
    }

    @Test func renameLinksUpdatesLinkAndNoteCardFile() throws {
        var scene = ExcalidrawScene()
        var card = Element.rectangle(x: 0, y: 0, width: 100, height: 60)
        card.link = "[[舊名]]"
        card.raw["customData"] = ["easynotes": ["file": "資料夾/舊名.md", "other": 1]]
        var aliased = Element.rectangle(x: 0, y: 0, width: 10, height: 10)
        aliased.link = "[[舊名|別名]]"
        var unrelated = Element.rectangle(x: 0, y: 0, width: 10, height: 10)
        unrelated.link = "[[舊名稱]]"
        scene.insert(card); scene.insert(aliased); scene.insert(unrelated)
        let unrelatedBefore = try #require(scene.element(unrelated.id)).raw

        let out = try #require(InkKind.renameLinks(in: scene.data(), from: "舊名", to: "新名"))
        let renamed = try ExcalidrawScene(data: out)
        #expect(renamed.element(card.id)?.link == "[[新名]]")
        let custom = renamed.element(card.id)?.customData?["easynotes"] as? [String: Any]
        #expect(custom?["file"] as? String == "資料夾/新名.md")
        #expect(custom?["other"] as? Int == 1)
        #expect(renamed.element(aliased.id)?.link == "[[新名|別名]]")
        #expect(renamed.element(card.id)?.version == 2)
        #expect(NSDictionary(dictionary: unrelatedBefore).isEqual(to: try #require(renamed.element(unrelated.id)).raw))
        #expect(InkKind.index(out, fileName: "b.excalidraw").links.sorted() == ["新名", "舊名稱"])

        #expect(InkKind.renameLinks(in: out, from: "不存在", to: "x") == nil)
    }
}
