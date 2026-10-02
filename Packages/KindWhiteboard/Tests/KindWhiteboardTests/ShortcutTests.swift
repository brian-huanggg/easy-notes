import CoreGraphics
import Foundation
import Testing
@testable import KindWhiteboard

/// 4c：鍵盤快捷鍵（Mac 與 iPad 外接鍵盤共用）
@MainActor
struct ShortcutTests {
    private func editor(_ scene: ExcalidrawScene = ExcalidrawScene()) throws -> BoardEditor {
        let session = FakeSession()
        session.files["board.excalidraw"] = try scene.data()
        let editor = BoardEditor(document: BoardDocument(path: "board.excalidraw", session: session))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return editor
    }

    @Test func keysMapToShortcuts() {
        #expect(BoardShortcut("v", command: false) == .tool(.select))
        #expect(BoardShortcut("R", command: false) == .tool(.rectangle))
        #expect(BoardShortcut("o", command: false) == .tool(.ellipse))
        #expect(BoardShortcut("a", command: false) == .tool(.arrow))
        #expect(BoardShortcut("t", command: false) == .tool(.text))
        #expect(BoardShortcut("f", command: false) == .tool(.frame))
        #expect(BoardShortcut("\u{7f}", command: false) == .delete)
        #expect(BoardShortcut("\u{F728}", command: false) == .delete)
        #expect(BoardShortcut("\u{1b}", command: false) == .escape)
        #expect(BoardShortcut("d", command: true) == .duplicate)
        #expect(BoardShortcut("a", command: true) == .selectAll)
        #expect(BoardShortcut("v", command: true) == .paste)
    }

    @Test func modifiersAndOtherKeysAreIgnored() {
        #expect(BoardShortcut("r", command: false, shift: true) == nil)
        #expect(BoardShortcut("r", command: false, option: true) == nil)
        #expect(BoardShortcut("r", command: false, control: true) == nil)
        #expect(BoardShortcut("d", command: true, shift: true) == nil)
        #expect(BoardShortcut("z", command: false) == nil)
        #expect(BoardShortcut("1", command: false) == nil)
    }

    @Test func toolShortcutsSwitchTool() throws {
        let editor = try editor()
        editor.inking = true
        #expect(editor.perform(.tool(.rectangle)))
        #expect(editor.tool == .rectangle)
        #expect(!editor.inking) // 選了結構工具就離開手寫模式
        editor.perform(.tool(.select))
        #expect(editor.tool == .select)
    }

    @Test func escapeCancelsToolThenSelection() throws {
        var scene = ExcalidrawScene()
        var el = Element.rectangle(x: 0, y: 0, width: 100, height: 100)
        el.raw["backgroundColor"] = "#ffc9c9"
        scene.insert(el)
        let editor = try editor(scene)
        editor.perform(.tool(.arrow)) // 建立工具會清掉選取
        editor.perform(.escape)
        #expect(editor.tool == .select) // 第一次 Esc 只回到選取工具
        editor.tap(at: CGPoint(x: 50, y: 50))
        #expect(editor.selection == [el.id])
        editor.perform(.escape)
        #expect(editor.selection.isEmpty) // 選取工具下的 Esc 取消選取
    }

    @Test func deleteDuplicateAndSelectAll() throws {
        var scene = ExcalidrawScene()
        let a = Element.rectangle(x: 0, y: 0, width: 100, height: 100)
        let b = Element.rectangle(x: 300, y: 0, width: 100, height: 100)
        scene.insert(a); scene.insert(b)
        let editor = try editor(scene)

        #expect(!editor.perform(.delete)) // 沒有選取：沒有處理
        editor.perform(.selectAll)
        #expect(editor.selection == [a.id, b.id])
        editor.perform(.duplicate)
        #expect(editor.document.scene.liveElements.count == 4)
        editor.perform(.selectAll)
        editor.perform(.delete)
        #expect(editor.document.scene.liveElements.isEmpty)
        editor.undoManager?.undo()
        #expect(editor.document.scene.liveElements.count == 4)
    }

    @Test func textEditingSwallowsEverythingButEscape() throws {
        let editor = try editor()
        editor.newText(at: CGPoint(x: 10, y: 10))
        #expect(editor.textEditing != nil)
        #expect(!editor.perform(.tool(.rectangle))) // 字母要打進文字框
        #expect(editor.tool == .select)
        #expect(!editor.perform(.delete))
        #expect(editor.textEditing != nil)
        // Esc 結束編輯（測試中沒有宿主交出內容 → 放棄）
        #expect(editor.perform(.escape))
        #expect(editor.textEditing == nil)
    }
}
