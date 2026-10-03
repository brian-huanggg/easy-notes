import CoreGraphics
import Foundation
import Testing
@testable import ExcalidrawKit
@testable import KindWhiteboard

/// 4c：樣式面板（模型層的 `setStyle` / `styleSummary`，編輯器的 Undo 與新元素沿用上次的樣式）
@MainActor
struct StyleTests {
    let path = "board.excalidraw"

    private func editor(_ scene: ExcalidrawScene = ExcalidrawScene()) throws -> (BoardEditor, UndoManager) {
        let session = FakeSession()
        session.files[path] = try scene.data()
        let editor = BoardEditor(document: BoardDocument(path: path, session: session))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.visibleRect = CGRect(x: 0, y: 0, width: 1000, height: 800)
        return (editor, undo)
    }

    // MARK: 模型

    @Test func appliesOnlyToElementsThatHaveTheProperty() {
        var scene = ExcalidrawScene()
        let box = Element.rectangle(x: 0, y: 0, width: 100, height: 100)
        let arrow = Element.arrow(from: CGPoint(x: 200, y: 0), to: CGPoint(x: 300, y: 0))
        let text = Element.text("字", x: 0, y: 200)
        let image = Element.image(fileId: "f", x: 300, y: 300, width: 50, height: 50)
        for el in [box, arrow, text, image] { scene.insert(el) }
        let all: Set = [box.id, arrow.id, text.id, image.id]

        scene.setStyle(all, .fill("#a5d8ff"))
        #expect(scene.element(box.id)?.raw["backgroundColor"] as? String == "#a5d8ff")
        #expect(scene.element(arrow.id)?.raw["backgroundColor"] as? String == "transparent")
        #expect(scene.element(box.id)?.version == box.version + 1)
        #expect(scene.element(arrow.id)?.version == arrow.version)
        #expect(scene.element(text.id)?.version == text.version)

        scene.setStyle(all, .strokeColor("#e03131"))
        #expect(scene.element(arrow.id)?.raw["strokeColor"] as? String == "#e03131")
        #expect(scene.element(text.id)?.raw["strokeColor"] as? String == "#1e1e1e") // 字色另外設定

        scene.setStyle(all, .opacity(50))
        #expect(scene.liveElements.allSatisfy { ($0.raw["opacity"] as? NSNumber)?.doubleValue == 50 })

        // 同樣的值不遞增 version
        let v = scene.element(box.id)!.version
        scene.setStyle([box.id], .fill("#a5d8ff"))
        #expect(scene.element(box.id)?.version == v)
    }

    @Test func roundnessFollowsExcalidrawPerShape() {
        var scene = ExcalidrawScene()
        let rect = Element.rectangle(x: 0, y: 0, width: 100, height: 100, rounded: false)
        let diamond = Element.diamond(x: 200, y: 0, width: 100, height: 100)
        let ellipse = Element.ellipse(x: 400, y: 0, width: 100, height: 100)
        for el in [rect, diamond, ellipse] { scene.insert(el) }

        scene.setStyle([rect.id, diamond.id, ellipse.id], .rounded(true))
        #expect((scene.element(rect.id)?.raw["roundness"] as? [String: Any])?["type"] as? Int == 3)
        #expect((scene.element(diamond.id)?.raw["roundness"] as? [String: Any])?["type"] as? Int == 2)
        #expect(scene.element(ellipse.id)?.raw["roundness"] is NSNull)
        #expect(scene.styleSummary([rect.id, diamond.id, ellipse.id]).rounded == [true])

        scene.setStyle([rect.id], .rounded(false))
        #expect(scene.element(rect.id)?.raw["roundness"] is NSNull)
    }

    @Test func arrowheads() {
        var scene = ExcalidrawScene()
        let arrow = Element.arrow(from: .zero, to: CGPoint(x: 100, y: 0))
        scene.insert(arrow)
        scene.setStyle([arrow.id], .arrowhead(.start, "triangle"))
        scene.setStyle([arrow.id], .arrowhead(.end, nil))
        let el = scene.element(arrow.id)!
        #expect(el.raw["startArrowhead"] as? String == "triangle")
        #expect(el.raw["endArrowhead"] is NSNull)
        let style = scene.styleSummary([arrow.id])
        #expect(style.startArrowheads == ["triangle"] && style.endArrowheads == [""])
        #expect(!style.strokeCanBeNone && style.fills.isEmpty)
    }

    @Test func textStyleReachesBoundTextAndRelayouts() throws {
        var scene = ExcalidrawScene()
        let box = Element.rectangle(x: 0, y: 0, width: 120, height: 60)
        scene.insert(box)
        let added = scene.addBoundText("一段比較長的文字會換行", to: box.id)
        let textID = try #require(added)
        let before = scene.element(box.id)!.height

        scene.setStyle([box.id], .fontSize(36))
        let text = scene.element(textID)!
        let container = scene.element(box.id)!
        #expect(text.fontSize == 36)
        #expect(container.height > before) // 文字變高，容器跟著長高
        #expect(abs(text.center.x - container.center.x) < 0.5 && abs(text.center.y - container.center.y) < 0.5)

        scene.setStyle([box.id], .textColor("#1971c2"))
        scene.setStyle([box.id], .opacity(30))
        #expect(scene.element(textID)?.raw["strokeColor"] as? String == "#1971c2")
        #expect(scene.element(box.id)?.raw["strokeColor"] as? String == "#1e1e1e")
        #expect((scene.element(textID)?.raw["opacity"] as? NSNumber)?.doubleValue == 30) // 形狀的透明度也套用到文字

        let style = scene.styleSummary([box.id])
        #expect(style.fontSizes == [36] && style.textColors == ["#1971c2"] && !style.fills.isEmpty)
        #expect(Fixture.bindingProblems(scene).isEmpty)
    }

    @Test func fontSizeKeepsAnchorOfStandaloneText() {
        var scene = ExcalidrawScene()
        var left = Element.text("左", x: 0, y: 0)
        var center = Element.text("中", x: 100, y: 0)
        center.raw["textAlign"] = "center"
        var right = Element.text("右", x: 200, y: 0)
        right.raw["textAlign"] = "right"
        for el in [left, center, right] { scene.insert(el) }
        left = scene.element(left.id)!; center = scene.element(center.id)!; right = scene.element(right.id)!

        scene.setStyle([left.id, center.id, right.id], .fontSize(36))
        let l = scene.element(left.id)!, c = scene.element(center.id)!, r = scene.element(right.id)!
        #expect(l.width > left.width && l.x == left.x && l.y == left.y)
        #expect(abs(c.center.x - center.center.x) < 0.001)
        #expect(abs((r.x + r.width) - (right.x + right.width)) < 0.001)
    }

    @Test func summaryReportsMixedValues() {
        var scene = ExcalidrawScene()
        var a = Element.rectangle(x: 0, y: 0, width: 10, height: 10)
        a.raw["backgroundColor"] = "#FFC9C9" // 檔案裡的大寫也比對得到
        let b = Element.ellipse(x: 20, y: 0, width: 10, height: 10)
        scene.insert(a); scene.insert(b)
        let style = scene.styleSummary([a.id, b.id])
        #expect(style.fills == ["#ffc9c9", "transparent"])
        #expect(style.strokeColors == ["#1e1e1e"] && style.strokeCanBeNone)
        #expect(style.rounded == [true]) // 只有矩形有邊角
        #expect(style.textColors.isEmpty)
        #expect(scene.styleSummary([]).isEmpty)
    }

    // MARK: 編輯器

    @Test func setStyleIsOneUndoAndPreviewIsOneUndo() throws {
        var scene = ExcalidrawScene()
        let box = Element.rectangle(x: 0, y: 0, width: 100, height: 100)
        scene.insert(box)
        let (editor, undo) = try editor(scene)
        editor.selection = [box.id]

        editor.setStyle(.fill("#b2f2bb"))
        #expect(editor.document.scene.element(box.id)?.raw["backgroundColor"] as? String == "#b2f2bb")
        undo.undo()
        #expect(editor.document.scene.element(box.id)?.raw["backgroundColor"] as? String == "transparent")
        #expect(editor.selection == [box.id])
        undo.redo()
        #expect(editor.document.scene.element(box.id)?.raw["backgroundColor"] as? String == "#b2f2bb")

        for value in [90.0, 70, 40] { editor.previewStyle(.opacity(value)) }
        editor.endStylePreview()
        #expect((editor.document.scene.element(box.id)?.raw["opacity"] as? NSNumber)?.doubleValue == 40)
        undo.undo() // 滑桿拖曳整段一次復原
        #expect((editor.document.scene.element(box.id)?.raw["opacity"] as? NSNumber)?.doubleValue == 100)
        undo.undo()
        #expect(editor.document.scene.element(box.id)?.raw["backgroundColor"] as? String == "transparent")
    }

    @Test func newElementsUseLastStyle() throws {
        var scene = ExcalidrawScene()
        let box = Element.rectangle(x: 0, y: 0, width: 100, height: 100)
        scene.insert(box)
        let (editor, _) = try editor(scene)
        editor.selection = [box.id]
        editor.setStyle(.fill("#ffec99"))
        editor.setStyle(.strokeStyle("dashed"))
        editor.setStyle(.rounded(false))
        editor.setStyle(.fontSize(28))
        editor.setStyle(.textColor("#e03131"))

        // 形狀面板：沿用填色與線型，但矩形 / 圓角矩形照面板的選擇
        editor.insert(.roundedRectangle)
        let shape = try #require(editor.selectedElements.first)
        #expect(shape.raw["backgroundColor"] as? String == "#ffec99" && shape.raw["strokeStyle"] as? String == "dashed")
        #expect(shape.raw["roundness"] is [String: Any])

        // 拖曳建立（Mac / 快捷鍵）也沿用，邊角也照上次
        editor.tool = .rectangle
        editor.begin(at: CGPoint(x: 600, y: 600))
        editor.drag(to: CGPoint(x: 700, y: 700))
        editor.end(at: CGPoint(x: 700, y: 700))
        let dragged = try #require(editor.selectedElements.first)
        #expect(dragged.raw["backgroundColor"] as? String == "#ffec99" && dragged.raw["roundness"] is NSNull)

        // 箭頭沒有填色
        editor.insert(.arrow)
        let arrow = try #require(editor.selectedElements.first)
        #expect(arrow.raw["backgroundColor"] as? String == "transparent" && arrow.raw["strokeStyle"] as? String == "dashed")

        // 新文字：文字框一開始就用上次的字級與字色
        editor.tool = .text
        editor.tap(at: CGPoint(x: 900, y: 50))
        #expect(editor.textEditing?.fontSize == 28 && editor.textEditing?.color == "#e03131")
        editor.endTextEditing("新")
        let text = try #require(editor.selectedElements.first)
        #expect(text.fontSize == 28 && text.raw["strokeColor"] as? String == "#e03131")

        // 形狀內的新文字也是
        #expect(editor.editText(of: shape.id))
        editor.endTextEditing("框內")
        let bound = try #require(editor.document.scene.liveElements.first { $0.containerId == shape.id })
        #expect(bound.fontSize == 28 && bound.raw["strokeColor"] as? String == "#e03131" && bound.textAlign == "center")

        // 便條紙不沿用
        editor.insertStickyNote()
        editor.cancelTextEditing()
        let sticky = try #require(editor.document.scene.liveElements.last { $0.type == .rectangle })
        #expect(sticky.raw["backgroundColor"] as? String == "#ffec99" && sticky.raw["strokeStyle"] as? String == "solid")
    }
}
