import CoreGraphics
import Foundation
import Testing
@testable import KindWhiteboard

/// 4c：編輯核心（選取、移動、縮放、建立、Undo），全部在畫布座標下
@MainActor
struct EditorTests {
    let path = "board.excalidraw"

    private func editor(_ scene: ExcalidrawScene = ExcalidrawScene()) throws -> (BoardEditor, FakeSession, UndoManager) {
        let session = FakeSession()
        session.files[path] = try scene.data()
        let editor = BoardEditor(document: BoardDocument(path: path, session: session))
        let undo = UndoManager()
        undo.groupsByEvent = false // 測試中沒有 run loop；每個操作自己開群組
        editor.undoManager = undo
        editor.tool = .select
        return (editor, session, undo)
    }

    private func drag(_ editor: BoardEditor, _ points: CGPoint..., extend: Bool = false) {
        guard let first = points.first, let last = points.last else { return }
        editor.begin(at: first, extend: extend)
        for p in points.dropFirst() { editor.drag(to: p) }
        editor.end(at: last)
    }

    private func filledRect(_ x: Double, _ y: Double, _ w: Double = 100, _ h: Double = 100) -> Element {
        var el = Element.rectangle(x: x, y: y, width: w, height: h)
        el.raw["backgroundColor"] = "#ffc9c9"
        return el
    }

    // MARK: 點選

    @Test func tapSelectsTopmostAndClearsOnEmpty() throws {
        var scene = ExcalidrawScene()
        let below = filledRect(0, 0), above = filledRect(50, 50)
        scene.insert(below); scene.insert(above)
        let (editor, _, _) = try editor(scene)

        editor.tap(at: CGPoint(x: 75, y: 75))
        #expect(editor.selection == [above.id])
        editor.tap(at: CGPoint(x: 10, y: 10), extend: true)
        #expect(editor.selection == [above.id, below.id])
        editor.tap(at: CGPoint(x: 10, y: 10), extend: true) // 再按一次 Shift = 移除
        #expect(editor.selection == [above.id])
        editor.tap(at: CGPoint(x: 500, y: 500))
        #expect(editor.selection.isEmpty)
    }

    @Test func transparentShapeIsHitOnlyOnItsOutline() throws {
        var scene = ExcalidrawScene()
        let r = Element.rectangle(x: 0, y: 0, width: 200, height: 200)
        scene.insert(r)
        let (editor, _, _) = try editor(scene)
        #expect(editor.element(at: CGPoint(x: 100, y: 100)) == nil)
        #expect(editor.element(at: CGPoint(x: 100, y: 3)) == r.id)
        editor.tap(at: CGPoint(x: 100, y: 3))
        #expect(editor.element(at: CGPoint(x: 100, y: 100)) == r.id) // 選取後點內部也算
    }

    @Test func boundTextSelectsItsContainerAndGroupsSelectTogether() throws {
        var scene = ExcalidrawScene()
        var a = filledRect(0, 0), b = filledRect(300, 0)
        a.groupIds = ["g"]; b.groupIds = ["g"]
        scene.insert(a); scene.insert(b)
        let box = filledRect(0, 300, 200, 100)
        scene.insert(box)
        scene.addBoundText("標題", to: box.id)
        let (editor, _, _) = try editor(scene)

        editor.tap(at: CGPoint(x: 10, y: 10))
        #expect(editor.selection == [a.id, b.id])
        editor.tap(at: CGPoint(x: 100, y: 350)) // 點在文字上
        #expect(editor.selection == [box.id])
    }

    @Test func lockedAndFreedrawAreNotSelectable() throws {
        var scene = ExcalidrawScene()
        var locked = filledRect(0, 0)
        locked.raw["locked"] = true
        scene.insert(locked)
        scene.replaceInk(with: [InkRoundTripTests.sampleStroke()])
        let (editor, _, _) = try editor(scene)
        editor.selectAll()
        #expect(editor.selection.isEmpty)
    }

    // MARK: 移動

    @Test func dragMovesSelectionAndRegistersOneUndo() throws {
        var scene = ExcalidrawScene()
        let r = filledRect(0, 0)
        scene.insert(r)
        let (editor, session, undo) = try editor(scene)

        drag(editor, CGPoint(x: 50, y: 50), CGPoint(x: 60, y: 55), CGPoint(x: 150, y: 80))
        var moved = try #require(editor.document.scene.element(r.id))
        #expect(moved.x == 100 && moved.y == 30)
        #expect(session.writes.isEmpty) // 只改記憶體，宿主停止操作後才存
        #expect(undo.canUndo && undo.undoActionName == "移動")

        let versionAfterMove = moved.version
        undo.undo()
        moved = try #require(editor.document.scene.element(r.id))
        #expect(moved.x == 0 && moved.y == 0)
        #expect(moved.version > versionAfterMove) // 復原時 version 繼續遞增
        undo.redo()
        moved = try #require(editor.document.scene.element(r.id))
        #expect(moved.x == 100 && moved.y == 30)
    }

    @Test func movingShapeCarriesBoundArrow() throws {
        let (scene, rect, ellipse, arrow) = Fixture.boundScene()
        let (editor, _, _) = try editor(scene)
        drag(editor, CGPoint(x: 150, y: 101), CGPoint(x: 150, y: 301)) // 抓矩形上邊往下 200
        let s = editor.document.scene
        #expect(s.element(rect)?.y == 300)
        let start = try #require(s.element(arrow)?.absolutePoints.first)
        #expect(start.y > 150) // 箭頭起點跟著形狀往下
        #expect(s.element(arrow)?.binding(.start)?.elementId == rect)
        #expect(s.element(arrow)?.binding(.end)?.elementId == ellipse)
        #expect(Fixture.bindingProblems(s).isEmpty)
    }

    @Test func fingerOnEmptySpaceCannotGrab() throws {
        var scene = ExcalidrawScene()
        scene.insert(filledRect(0, 0))
        let (editor, _, _) = try editor(scene)
        #expect(editor.canGrab(at: CGPoint(x: 50, y: 50)))
        #expect(!editor.canGrab(at: CGPoint(x: 500, y: 500)))
        editor.inking = true // 手寫模式（手指長按）：空白處不框選
        #expect(!editor.begin(at: CGPoint(x: 500, y: 500)))
        #expect(editor.begin(at: CGPoint(x: 50, y: 50)))
    }

    // MARK: 框選

    @Test func marqueeSelectsElementsFullyInside() throws {
        var scene = ExcalidrawScene()
        let inside = filledRect(10, 10, 50, 50), partly = filledRect(150, 10, 100, 50)
        scene.insert(inside); scene.insert(partly)
        let (editor, _, undo) = try editor(scene)
        drag(editor, CGPoint(x: -20, y: -20), CGPoint(x: 200, y: 100))
        #expect(editor.selection == [inside.id])
        #expect(editor.marquee == nil)
        #expect(!undo.canUndo) // 框選不改場景
    }

    // MARK: 縮放

    @Test func cornerHandleKeepsOppositeCornerFixed() throws {
        var scene = ExcalidrawScene()
        let r = filledRect(0, 0, 100, 100)
        scene.insert(r)
        let (editor, _, _) = try editor(scene)
        editor.tap(at: CGPoint(x: 50, y: 50))
        #expect(editor.handle(at: CGPoint(x: 101, y: 99)) == .resize(dx: 1, dy: 1))
        drag(editor, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 150))
        let el = try #require(editor.document.scene.element(r.id))
        #expect(el.rect == CGRect(x: 0, y: 0, width: 300, height: 150))

        // 拉過頭不翻轉，最小 1
        drag(editor, CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 500))
        let min = try #require(editor.document.scene.element(r.id))
        #expect(min.width == 1 && min.height == 1 && min.x == 299 && min.y == 149)
    }

    @Test func rotatedResizeKeepsOppositeCornerFixedOnScreen() throws {
        var scene = ExcalidrawScene()
        var r = filledRect(0, 0, 200, 100)
        r.angle = .pi / 2
        scene.insert(r)
        let (editor, _, _) = try editor(scene)
        let opposite = Geometry.point(in: r, ratio: CGPoint(x: 0, y: 0)) // 左上角（旋轉後的位置）
        let handle = Geometry.point(in: r, ratio: CGPoint(x: 1, y: 1))
        editor.tap(at: r.center)
        #expect(editor.handle(at: handle) == .resize(dx: 1, dy: 1))
        drag(editor, handle, CGPoint(x: handle.x - 50, y: handle.y + 100))
        let el = try #require(editor.document.scene.element(r.id))
        let now = Geometry.point(in: el, ratio: CGPoint(x: 0, y: 0))
        #expect(abs(now.x - opposite.x) < 1e-6 && abs(now.y - opposite.y) < 1e-6)
        #expect(abs(el.width - 300) < 1e-6 && abs(el.height - 150) < 1e-6)
    }

    @Test func multiSelectionResizesProportionally() throws {
        var scene = ExcalidrawScene()
        let a = filledRect(0, 0, 100, 100), b = filledRect(200, 0, 100, 100)
        scene.insert(a); scene.insert(b)
        let (editor, _, _) = try editor(scene)
        editor.selectAll()
        drag(editor, CGPoint(x: 300, y: 50), CGPoint(x: 600, y: 50)) // 右邊的控制點：寬度 ×2
        let s = editor.document.scene
        #expect(s.element(a.id)?.rect == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(s.element(b.id)?.rect == CGRect(x: 400, y: 0, width: 200, height: 100))
    }

    @Test func resizingLinesScalesPointsWithinTheirBox() throws {
        var scene = ExcalidrawScene()
        // 往左上畫的箭頭：(x, y) 是第一個點，外框在它的左上方
        let arrow = Element.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 0, y: 0))
        let other = filledRect(300, 300, 10, 10)
        scene.insert(arrow); scene.insert(other)
        let (editor, _, _) = try editor(scene)
        editor.selectAll()
        drag(editor, CGPoint(x: 310, y: 310), CGPoint(x: 620, y: 620)) // 整體 ×2（以左上角固定）
        let pts = try #require(editor.document.scene.element(arrow.id)?.absolutePoints)
        #expect(pts == [CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 0)])
    }

    // MARK: 建立

    @Test func dragCreatesShapeThenReturnsToSelect() throws {
        let (editor, _, undo) = try editor()
        editor.tool = .rectangle
        drag(editor, CGPoint(x: 100, y: 100), CGPoint(x: 40, y: 20))
        let el = try #require(editor.document.scene.liveElements.first)
        #expect(el.type == .rectangle)
        #expect(el.rect == CGRect(x: 40, y: 20, width: 60, height: 80))
        #expect(editor.tool == .select)
        #expect(editor.selection == [el.id])

        undo.undo()
        #expect(editor.document.scene.liveElements.isEmpty)
        #expect(editor.document.scene.element(el.id)?.isDeleted == true) // 墓碑，version 遞增
        undo.redo()
        #expect(editor.document.scene.liveElements.map(\.id) == [el.id])
    }

    @Test func tinyDragCreatesNothing() throws {
        let (editor, _, undo) = try editor()
        editor.tool = .ellipse
        drag(editor, CGPoint(x: 100, y: 100), CGPoint(x: 102, y: 101))
        #expect(editor.document.scene.elements.isEmpty)
        #expect(!undo.canUndo)
        #expect(editor.tool == .ellipse)
    }

    @Test func cancelledCreationLeavesNoTrace() throws {
        let (editor, _, undo) = try editor()
        editor.tool = .rectangle
        editor.begin(at: CGPoint(x: 0, y: 0))
        editor.drag(to: CGPoint(x: 80, y: 80))
        #expect(editor.document.scene.elements.count == 1)
        editor.cancel() // 例如第二根手指放上來
        #expect(editor.document.scene.elements.isEmpty) // 沒存過檔：連墓碑都不留
        #expect(!undo.canUndo)
    }

    @Test func arrowBindsToShapesAtBothEnds() throws {
        var scene = ExcalidrawScene()
        let a = filledRect(0, 0), b = Element.ellipse(x: 400, y: 0, width: 100, height: 100)
        scene.insert(a); scene.insert(b)
        let (editor, _, undo) = try editor(scene)
        editor.tool = .arrow
        drag(editor, CGPoint(x: 50, y: 50), CGPoint(x: 200, y: 50), CGPoint(x: 450, y: 50))
        let arrow = try #require(editor.document.scene.liveElements.first { $0.type == .arrow })
        #expect(arrow.binding(.start)?.elementId == a.id)
        #expect(arrow.binding(.end)?.elementId == b.id)
        // 端點在形狀外 gap 處，不在形狀裡
        let pts = arrow.absolutePoints
        #expect(abs(pts[0].x - 105) < 1e-6 && abs(pts[1].x - 395) < 1e-6)
        #expect(Fixture.bindingProblems(editor.document.scene).isEmpty)

        undo.undo() // 一次復原整個建立（含兩端綁定與 boundElements）
        #expect(Fixture.bindingProblems(editor.document.scene).isEmpty)
        #expect(editor.document.scene.element(a.id)?.boundElements.isEmpty == true)
    }

    @Test func draggingArrowEndRebindsOrUnbinds() throws {
        var (scene, rect, ellipse, arrow) = Fixture.boundScene()
        let third = filledRect(500, 400)
        scene.insert(third)
        let (editor, _, _) = try editor(scene)
        editor.tap(at: CGPoint(x: 400, y: 150))
        #expect(editor.selection == [arrow])
        let end = try #require(editor.document.scene.element(arrow)?.absolutePoints.last)
        #expect(editor.handle(at: end) == .end(.end))

        drag(editor, end, CGPoint(x: 550, y: 450))
        var s = editor.document.scene
        #expect(s.element(arrow)?.binding(.end)?.elementId == third.id)
        #expect(s.element(ellipse)?.boundElements.isEmpty == true)
        #expect(Fixture.bindingProblems(s).isEmpty)

        let newEnd = try #require(s.element(arrow)?.absolutePoints.last)
        drag(editor, newEnd, CGPoint(x: 900, y: 900))
        s = editor.document.scene
        #expect(s.element(arrow)?.binding(.end) == nil)
        #expect(s.element(arrow)?.binding(.start)?.elementId == rect)
        #expect(Fixture.bindingProblems(s).isEmpty)
    }

    @Test func frameCollectsElementsInside() throws {
        var scene = ExcalidrawScene()
        let inside = filledRect(50, 50, 50, 50), outside = filledRect(500, 50, 50, 50)
        scene.insert(inside); scene.insert(outside)
        let (editor, _, _) = try editor(scene)
        editor.tool = .frame
        drag(editor, CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 300))
        let frame = try #require(editor.document.scene.liveElements.first { $0.type == .frame })
        #expect(editor.document.scene.element(inside.id)?.frameId == frame.id)
        #expect(editor.document.scene.element(outside.id)?.frameId == nil)
    }

    // MARK: 刪除、再製、剪貼簿

    @Test func deleteAndUndoRestoresBindings() throws {
        let (scene, rect, _, arrow) = Fixture.boundScene()
        let (editor, _, undo) = try editor(scene)
        editor.tap(at: CGPoint(x: 150, y: 101))
        editor.deleteSelection()
        #expect(editor.document.scene.element(arrow)?.binding(.start) == nil)
        undo.undo()
        let s = editor.document.scene
        #expect(s.element(rect)?.isDeleted == false)
        #expect(s.element(arrow)?.binding(.start)?.elementId == rect)
        #expect(Fixture.bindingProblems(s).isEmpty)
        #expect(editor.selection == [rect]) // 復原後選取被復原的元素（不含連帶改到的箭頭）
    }

    @Test func duplicateCopiesBoundTextWithRemappedIDs() throws {
        var scene = ExcalidrawScene()
        let box = filledRect(0, 0, 200, 100)
        scene.insert(box)
        let added = scene.addBoundText("重點", to: box.id)
        let text = try #require(added)
        let (editor, _, _) = try editor(scene)
        editor.tap(at: CGPoint(x: 10, y: 10))
        editor.duplicateSelection()

        let s = editor.document.scene
        #expect(s.liveElements.count == 4)
        let copy = try #require(editor.selection.first.flatMap { s.element($0) })
        #expect(editor.selection.count == 1 && copy.id != box.id)
        #expect(copy.x == 10 && copy.y == 10)
        let copiedText = try #require(s.liveElements.first { $0.containerId == copy.id })
        #expect(copiedText.id != text && copiedText.originalText == "重點")
        #expect(copy.boundElements.map(\.id) == [copiedText.id])
        #expect(Fixture.bindingProblems(s).isEmpty)
    }

    @Test func clipboardRoundTripKeepsInternalBindings() throws {
        let (scene, rect, ellipse, arrow) = Fixture.boundScene()
        let (editor, _, _) = try editor(scene)
        editor.selectAll()
        let data = try #require(editor.copySelection())
        #expect(editor.paste(data, center: CGPoint(x: 2000, y: 2000)))
        let s = editor.document.scene
        #expect(s.liveElements.count == 6)
        #expect(editor.selection.count == 3 && editor.selection.isDisjoint(with: [rect, ellipse, arrow]))
        #expect(Fixture.bindingProblems(s).isEmpty)
        #expect(!editor.paste(Data("不是白板".utf8), center: .zero))
    }

    // MARK: 存檔與外部變動

    @Test func editsAreWrittenOnCommitOnly() throws {
        var scene = ExcalidrawScene()
        let r = filledRect(0, 0)
        scene.insert(r)
        let (editor, session, _) = try editor(scene)
        drag(editor, CGPoint(x: 50, y: 50), CGPoint(x: 70, y: 50))
        #expect(session.writes.isEmpty)
        editor.document.commit()
        let saved = try ExcalidrawScene(data: try #require(session.writes.last?.data))
        #expect(saved.element(r.id)?.x == 20)
        editor.document.commit() // 沒有新的變動：不再寫
        #expect(session.writes.count == 1)
    }

    @Test func externalDeleteDropsSelection() throws {
        var scene = ExcalidrawScene()
        let r = filledRect(0, 0)
        scene.insert(r)
        let (editor, session, _) = try editor(scene)
        editor.tap(at: CGPoint(x: 50, y: 50))
        var disk = try ExcalidrawScene(data: session.files[path]!)
        disk.delete([r.id])
        editor.document.externalChange(try disk.data())
        editor.sceneDidChange()
        #expect(editor.selection.isEmpty)
    }

    @Test func changeDetectionReportsStructuralEdits() throws {
        let (scene, rect, _, arrow) = Fixture.boundScene()
        var moved = scene
        moved.move([rect], dx: 10, dy: 0)
        let change = BoardEditor.changes(from: scene.elements, to: moved.elements)
        #expect(change.ids == [rect, arrow] && !change.structural)
        var added = scene
        added.insert(Element.rectangle(x: 0, y: 0, width: 1, height: 1))
        #expect(BoardEditor.changes(from: scene.elements, to: added.elements).structural)
    }

    // MARK: 文字

    @Test func textToolTapCreatesTextAndUndoRemovesIt() throws {
        let (editor, _, undo) = try editor()
        editor.tool = .text
        editor.tap(at: CGPoint(x: 100, y: 100))
        let editing = try #require(editor.textEditing)
        #expect(editing.id == nil && editing.rect(for: "").midY == 100) // 插入點垂直置中在點下的位置
        #expect(editor.document.scene.liveElements.isEmpty) // 輸入中不碰場景

        editor.endTextEditing("你好\n世界")
        let text = try #require(editor.document.scene.liveElements.first)
        #expect(text.type == .text && text.originalText == "你好\n世界" && text.x == 100)
        #expect(editor.tool == .select && editor.selection == [text.id] && editor.textEditing == nil)
        undo.undo()
        #expect(editor.document.scene.liveElements.isEmpty)
        undo.redo()
        #expect(editor.document.scene.liveElements.first?.originalText == "你好\n世界")
        #expect(editor.selection == [text.id])
    }

    @Test func emptyNewTextCreatesNothing() throws {
        let (editor, _, undo) = try editor()
        #expect(editor.editText(at: CGPoint(x: 0, y: 0)))
        editor.endTextEditing("  \n")
        #expect(editor.document.scene.elements.isEmpty)
        #expect(!undo.canUndo)
    }

    @Test func editingShapeAddsBoundTextAndClearingItKeepsShape() throws {
        var scene = ExcalidrawScene()
        let box = filledRect(0, 0, 200, 100)
        scene.insert(box)
        let (editor, _, undo) = try editor(scene)

        #expect(editor.editText(at: CGPoint(x: 100, y: 50))) // 雙擊形狀
        let editing = try #require(editor.textEditing)
        #expect(editing.containerId == box.id && editing.id == nil)
        #expect(editing.rect(for: "標題").midX == 100 && editing.rect(for: "標題").midY == 50)
        editor.endTextEditing("標題")
        var s = editor.document.scene
        let text = try #require(s.liveElements.first { $0.containerId == box.id })
        #expect(text.originalText == "標題" && editor.selection == [box.id])
        #expect(s.element(box.id)?.boundElements.map(\.id) == [text.id])

        editor.tap(at: CGPoint(x: 500, y: 500))
        #expect(editor.editText(at: CGPoint(x: 100, y: 50))) // 點在文字上 → 編輯同一段文字
        #expect(editor.textEditing?.id == text.id && editor.textEditing?.text == "標題")
        editor.endTextEditing("")
        s = editor.document.scene
        #expect(s.element(text.id)?.isDeleted == true && s.element(box.id)?.isDeleted == false)
        #expect(s.element(box.id)?.boundElements.isEmpty == true)
        undo.undo()
        #expect(editor.document.scene.element(text.id)?.isDeleted == false)
        #expect(Fixture.bindingProblems(editor.document.scene).isEmpty)
    }

    @Test func unchangedTextRegistersNoUndo() throws {
        var scene = ExcalidrawScene()
        let text = Element.text("原本", x: 40, y: 60)
        scene.insert(text)
        let (editor, _, undo) = try editor(scene)
        #expect(editor.editText(of: text.id))
        #expect(editor.textEditing?.rect(for: "原本").origin == CGPoint(x: 40, y: 60))
        editor.endTextEditing("原本")
        #expect(!undo.canUndo)
        #expect(editor.document.scene.element(text.id)?.version == text.version)
    }

    @Test func switchingToolCommitsTextThroughHost() throws {
        let (editor, _, _) = try editor()
        editor.requestTextCommit = { [weak editor] in editor?.endTextEditing("便條") }
        editor.tool = .text
        editor.tap(at: CGPoint(x: 0, y: 0))
        editor.tool = .rectangle
        #expect(editor.tool == .rectangle) // 不被結束編輯切回選取
        #expect(editor.document.scene.liveElements.first?.originalText == "便條")
    }

    // MARK: 圖片

    @Test func insertedImageIsCenteredInViewAndUndoable() async throws {
        let (editor, _, undo) = try editor()
        editor.visibleRect = CGRect(x: 1000, y: 1000, width: 800, height: 600)
        editor.zoom = 0.5
        #expect(await editor.insertImage(Fixture.pngData(width: 1200, height: 600)))
        let image = try #require(editor.document.scene.liveElements.first)
        #expect(image.type == .image && editor.selection == [image.id])
        #expect(image.width == 800 && image.height == 400) // 螢幕上 400 點 ÷ 縮放 0.5
        #expect(image.center == CGPoint(x: 1400, y: 1300))
        #expect(editor.document.scene.imageData(fileId: try #require(image.fileId)) != nil)
        undo.undo()
        #expect(editor.document.scene.liveElements.isEmpty)
        #expect(await !editor.insertImage(Data("不是圖片".utf8)))
    }

    // MARK: 工具列插入（Freeform 式）

    @Test func insertShapeAtViewCenterAndOffsetsRepeats() throws {
        let (editor, _, undo) = try editor()
        editor.visibleRect = CGRect(x: 0, y: 0, width: 1000, height: 800)
        editor.zoom = 2
        editor.inking = true
        editor.insert(.diamond)
        let first = try #require(editor.selectedElements.first)
        #expect(first.type == .diamond && editor.selection.count == 1)
        #expect(ElementGeometry.box(first) == CGRect(x: 460, y: 360, width: 80, height: 80)) // 160 螢幕點 ÷ 2
        #expect(!editor.inking) // 選其他工具就離開手寫模式
        editor.insert(.rectangle)
        let second = try #require(editor.selectedElements.first)
        #expect(second.x == 470 && second.y == 370) // 錯開 20 螢幕點
        #expect(!(second.raw["roundness"] is [String: Any]))
        undo.undo()
        #expect(editor.document.scene.liveElements.count == 1)
    }

    @Test func insertArrowIsHorizontalThroughCenter() throws {
        let (editor, _, _) = try editor()
        editor.visibleRect = CGRect(x: -500, y: -500, width: 1000, height: 1000)
        editor.insert(.arrow)
        let arrow = try #require(editor.selectedElements.first)
        #expect(arrow.type == .arrow)
        #expect(arrow.absolutePoints == [CGPoint(x: -100, y: 0), CGPoint(x: 100, y: 0)])
    }

    @Test func stickyNoteStartsEditingItsText() throws {
        let (editor, _, _) = try editor()
        editor.visibleRect = CGRect(x: 0, y: 0, width: 400, height: 400)
        editor.inking = true
        editor.insertStickyNote()
        #expect(!editor.inking)
        let note = try #require(editor.document.scene.liveElements.first)
        #expect(note.raw["backgroundColor"] as? String == "#ffec99")
        #expect(note.raw["strokeColor"] as? String == "transparent")
        #expect(editor.textEditing?.containerId == note.id)
        editor.endTextEditing("待辦")
        let text = try #require(editor.document.scene.liveElements.first { $0.type == .text })
        #expect(text.containerId == note.id && editor.selection == [note.id])
    }

    @Test func insertTextStartsNewTextEvenOverElements() throws {
        var scene = ExcalidrawScene()
        scene.insert(filledRect(0, 0, 400, 400))
        let (editor, _, _) = try editor(scene)
        editor.visibleRect = CGRect(x: 0, y: 0, width: 400, height: 400)
        editor.insertText()
        #expect(editor.textEditing?.id == nil && editor.textEditing?.containerId == nil)
    }

    /// 背景是 App 偏好設定：新白板的 appState 只有 Excalidraw 的欄位
    @Test func templateHasOnlyExcalidrawAppState() throws {
        let scene = try ExcalidrawScene(data: InkKind.template(title: ""))
        let keys = Set((scene.raw["appState"] as? [String: Any] ?? [:]).keys)
        #expect(keys == ["viewBackgroundColor", "gridSize"])
    }

    // MARK: 套索選取

    @Test func lassoSelectsElementsFullyInsidePolygon() throws {
        var scene = ExcalidrawScene()
        let inside = filledRect(10, 10, 50, 50), partly = filledRect(150, 10, 100, 50)
        scene.insert(inside); scene.insert(partly)
        let (editor, _, undo) = try editor(scene)
        editor.selectionShape = .lasso
        drag(editor, CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 100))
        #expect(editor.selection == [inside.id])
        #expect(editor.lasso == nil && editor.marquee == nil)
        #expect(!undo.canUndo) // 選取不進 Undo
    }

    /// 凹形套索：矩形範圍包住、但形狀不在套索內的元素不選
    @Test func concaveLassoExcludesElementsInTheNotch() throws {
        var scene = ExcalidrawScene()
        let left = filledRect(10, 10, 30, 30), notch = filledRect(110, 10, 30, 30)
        scene.insert(left); scene.insert(notch)
        let (editor, _, _) = try editor(scene)
        editor.selectionShape = .lasso
        // U 形：左右兩支往上，中間 (100…150, 0…60) 是缺口
        drag(editor, CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 60, y: 60), CGPoint(x: 200, y: 60),
             CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 100))
        #expect(editor.selection == [left.id])
        #expect(!editor.lassoed([CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 60, y: 60), CGPoint(x: 200, y: 60),
                                 CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 100)]).contains(notch.id))
    }

    /// 橢圓用輪廓取樣：貼著圓周的菱形套索（外框四角在套索外）也選得到
    @Test func lassoUsesShapeOutlineNotBoundingBox() throws {
        var scene = ExcalidrawScene()
        let circle = Element.ellipse(x: 0, y: 0, width: 100, height: 100)
        scene.insert(circle)
        let (editor, _, _) = try editor(scene)
        let diamond = [CGPoint(x: 50, y: -60), CGPoint(x: 160, y: 50), CGPoint(x: 50, y: 160), CGPoint(x: -60, y: 50)]
        #expect(editor.lassoed(diamond) == [circle.id])
        #expect(editor.lassoed(diamond.map { CGPoint(x: ($0.x - 50) * 0.3 + 50, y: ($0.y - 50) * 0.3 + 50) }).isEmpty)
    }

    @Test func lassoCancelClearsPath() throws {
        let (editor, _, _) = try editor()
        editor.selectionShape = .lasso
        editor.begin(at: CGPoint(x: 0, y: 0))
        editor.drag(to: CGPoint(x: 50, y: 0))
        #expect(editor.lasso?.count == 2)
        editor.cancel()
        #expect(editor.lasso == nil)
    }
}
