import CoreGraphics
import Foundation
import Testing
@testable import ExcalidrawKit
@testable import KindWhiteboard

/// 4c：箭頭連接點吸附（形狀上下左右 4 個連接點，寫入 `fixedPoint`）
@MainActor
struct ArrowSnapTests {
    let path = "board.excalidraw"

    private func editor(_ scene: ExcalidrawScene) throws -> (BoardEditor, UndoManager) {
        let session = FakeSession()
        session.files[path] = try scene.data()
        let editor = BoardEditor(document: BoardDocument(path: path, session: session))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (editor, undo)
    }

    private func filledRect(_ x: Double, _ y: Double, _ w: Double = 100, _ h: Double = 100) -> Element {
        var el = Element.rectangle(x: x, y: y, width: w, height: h)
        el.raw["backgroundColor"] = "#ffc9c9"
        return el
    }

    private func near(_ a: CGPoint?, _ b: CGPoint, _ tolerance: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    @Test func creatingArrowSnapsBothEndsToConnectors() throws {
        var scene = ExcalidrawScene()
        let a = filledRect(0, 0), b = filledRect(400, 0)
        scene.insert(a); scene.insert(b)
        let (editor, undo) = try editor(scene)
        editor.tool = .arrow

        editor.begin(at: CGPoint(x: 96, y: 58)) // a 的右邊中點附近
        editor.drag(to: CGPoint(x: 250, y: 40))
        #expect(editor.bindTarget == nil)
        editor.drag(to: CGPoint(x: 408, y: 45)) // b 的左邊中點附近
        #expect(editor.bindTarget == BindPick(id: b.id, side: 3))
        // 拖曳中端點已經顯示在吸附位置
        let dragging = try #require(editor.document.scene.liveElements.first { $0.type == .arrow })
        #expect(near(dragging.absolutePoints.first, CGPoint(x: 105, y: 50)))
        #expect(near(dragging.absolutePoints.last, CGPoint(x: 395, y: 50)))
        editor.end(at: CGPoint(x: 408, y: 45))

        let arrow = try #require(editor.document.scene.liveElements.first { $0.type == .arrow })
        #expect(arrow.binding(.start)?.elementId == a.id && arrow.binding(.start)?.fixedPoint == CGPoint(x: 1, y: 0.5))
        #expect(arrow.binding(.end)?.elementId == b.id && arrow.binding(.end)?.fixedPoint == CGPoint(x: 0, y: 0.5))
        #expect(near(arrow.absolutePoints.first, CGPoint(x: 105, y: 50)))
        #expect(near(arrow.absolutePoints.last, CGPoint(x: 395, y: 50)))
        #expect(editor.bindTarget == nil)
        #expect(Fixture.bindingProblems(editor.document.scene).isEmpty)
        undo.undo()
        #expect(editor.document.scene.liveElements.count == 2)
    }

    @Test func connectorEndpointStaysOnItsSideWhenShapeMoves() throws {
        var scene = ExcalidrawScene()
        let box = filledRect(0, 0)
        scene.insert(box)
        let arrow = Element.arrow(from: CGPoint(x: 50, y: 300), to: CGPoint(x: 50, y: 150))
        scene.insert(arrow)
        // 箭頭從形狀下方過來，卻綁在上緣：端點仍停在上緣外 gap 處，不會從下緣進去
        scene.bind(arrow: arrow.id, .end, to: box.id, fixedPoint: CGPoint(x: 0.5, y: 0), gap: 5)
        #expect(near(scene.element(arrow.id)?.absolutePoints.last, CGPoint(x: 50, y: -5)))

        scene.move([box.id], dx: 200, dy: 20)
        #expect(near(scene.element(arrow.id)?.absolutePoints.last, CGPoint(x: 250, y: 15)))

        scene.resize(box.id, to: CGRect(x: 200, y: 20, width: 300, height: 100))
        #expect(near(scene.element(arrow.id)?.absolutePoints.last, CGPoint(x: 350, y: 15)))

        // 旋轉 90°：上緣中點轉到右邊，外法線也跟著轉
        _ = scene.mutate(box.id) { $0.angle = .pi / 2 }
        scene.rebindArrows(movedIDs: [box.id])
        #expect(near(scene.element(arrow.id)?.absolutePoints.last, CGPoint(x: 405, y: 70), 1e-6))
    }

    @Test func droppingAwayFromConnectorsKeepsProjectedFixedPoint() throws {
        var scene = ExcalidrawScene()
        let box = filledRect(0, 0, 200, 200)
        scene.insert(box)
        let (editor, _) = try editor(scene)
        editor.tool = .arrow
        editor.begin(at: CGPoint(x: 600, y: 600))
        editor.drag(to: CGPoint(x: 300, y: 300))
        editor.end(at: CGPoint(x: 150, y: 160)) // 在形狀內，離連接點都遠
        let arrow = try #require(editor.document.scene.liveElements.first { $0.type == .arrow })
        let fixed = try #require(arrow.binding(.end)?.fixedPoint)
        #expect(Geometry.side(fixed) == nil)
        #expect(near(fixed, CGPoint(x: 0.75, y: 0.8)))
    }

    @Test func draggingArrowEndSnapsToRotatedShape() throws {
        var scene = ExcalidrawScene()
        var box = filledRect(0, 0, 200, 100)
        box.angle = .pi / 2 // 繞中心 (100, 50) 轉 90°：下緣中點 (100, 100) 轉到 (50, 50)
        scene.insert(box)
        let arrow = Element.arrow(from: CGPoint(x: -300, y: 50), to: CGPoint(x: -200, y: 50))
        scene.insert(arrow)
        let (editor, _) = try editor(scene)
        editor.selection = [arrow.id]

        let end = try #require(editor.document.scene.element(arrow.id)?.absolutePoints.last)
        editor.begin(at: end)
        editor.drag(to: CGPoint(x: 45, y: 55))
        #expect(editor.bindTarget == BindPick(id: box.id, side: 2))
        editor.end(at: CGPoint(x: 45, y: 55))
        let bound = try #require(editor.document.scene.element(arrow.id))
        #expect(bound.binding(.end)?.fixedPoint == CGPoint(x: 0.5, y: 1))
        #expect(near(bound.absolutePoints.last, CGPoint(x: 45, y: 50), 1e-6)) // 下緣外法線轉 90° 後朝左
    }

    @Test func snapRadiusIsInScreenPoints() throws {
        var scene = ExcalidrawScene()
        let box = filledRect(0, 0)
        scene.insert(box)
        let (editor, _) = try editor(scene)
        let p = CGPoint(x: 120, y: 50) // 右邊中點外 20
        #expect(editor.bindPick(at: p) == nil)
        editor.zoom = 0.5 // 吸附距離 = 14 / 0.5 = 28
        #expect(editor.bindPick(at: p) == BindPick(id: box.id, side: 1))
    }
}
