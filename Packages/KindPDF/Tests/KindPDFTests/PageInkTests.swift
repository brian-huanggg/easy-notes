import CoreGraphics
import ExcalidrawKit
import Foundation
import PencilKit
import Testing
@testable import KindPDF

@Suite struct PageInkTests {
    /// overlay 是頁面的 2 倍、旋轉 90°：頁面 → 畫布 → 頁面，位置與筆寬不變，`replaceInk` 認得是同一筆
    @Test func roundTripThroughCanvasKeepsStrokes() throws {
        var scene = ExcalidrawScene()
        scene.replaceInk(with: [Sample.stroke()])
        let before = scene.elements
        let pageToView = CGAffineTransform(a: 0, b: 2, c: -2, d: 0, tx: 1584, ty: 0)

        let drawing = PageInk.drawing(scene, pageToView: pageToView)
        let strokes = PageInk.strokes(drawing, viewToPage: pageToView.inverted())

        let original = try #require(scene.inkStrokes.first)
        let back = try #require(strokes.first)
        #expect(back.matches(original))
        #expect(zip(back.points, original.points).allSatisfy { abs($0.size - $1.size) < 1e-3 })
        scene.replaceInk(with: strokes)
        #expect(PageInk.snapshots(from: before, to: scene.elements).undo.isEmpty)
    }

    /// 在畫布上畫的新筆畫（點在 overlay 座標、沒有 transform）：筆寬換成頁面單位
    @Test func newCanvasStrokeScalesToPage() throws {
        let point = PKStrokePoint(location: CGPoint(x: 100, y: 40), timeOffset: 0, size: CGSize(width: 6, height: 6),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, point], creationDate: Date()))
        let viewToPage = CGAffineTransform(scaleX: 2, y: 2).inverted()
        let page = try #require(PageInk.strokes(PKDrawing(strokes: [stroke]), viewToPage: viewToPage).first)
        #expect(abs(page.points[0].x - 50) < 1e-3 && abs(page.points[0].y - 20) < 1e-3)
        #expect(abs(page.points[0].size - 3) < 1e-3)
    }

    /// Undo 快照：新增的元素 undo 為 nil、刪除（墓碑）記下前一版
    @Test func snapshotsRecordChangedElements() throws {
        var scene = ExcalidrawScene()
        scene.replaceInk(with: [Sample.stroke(x: 10)])
        let first = scene.elements
        let id = try #require(first.first?["id"] as? String)
        scene.replaceInk(with: [Sample.stroke(x: 200)])
        let (undo, redo) = PageInk.snapshots(from: first, to: scene.elements)
        #expect(undo.count == 2 && redo.count == 2)
        #expect((undo[id] ?? nil)?["isDeleted"] as? Bool == false)
        #expect((redo[id] ?? nil)?["isDeleted"] as? Bool == true)
        let added = try #require(undo.first { $0.key != id })
        #expect(added.value == nil)

        scene.restore(undo)
        #expect(scene.inkStrokes.count == 1)
        #expect(scene.inkStrokes.first?.points.first?.x == 10)
    }
}
