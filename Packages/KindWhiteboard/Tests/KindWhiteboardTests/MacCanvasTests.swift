#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import KindWhiteboard

/// 4c：macOS 宿主（`BoardMacCanvasView`）。放進離屏視窗，用合成的滑鼠 / 鍵盤事件驅動
@MainActor
struct MacCanvasTests {
    /// 場景座標 (100,100) 起的紅色矩形 200×100；初始畫面 origin = (60, 60)，所以矩形在螢幕 (42,42)…(242,142)
    private func setUp(_ scene: ExcalidrawScene? = nil) throws -> (BoardMacCanvasView, BoardEditor, NSWindow, FakeSession) {
        var scene = scene ?? {
            var s = ExcalidrawScene()
            var r = Element.rectangle(x: 100, y: 100, width: 200, height: 100)
            r.raw["backgroundColor"] = "#ff0000"
            r.raw["strokeColor"] = "#ff0000"
            s.insert(r)
            return s
        }()
        let session = FakeSession()
        session.files["board.excalidraw"] = try scene.data()
        scene = ExcalidrawScene()
        let document = BoardDocument(path: "board.excalidraw", session: session)
        let editor = BoardEditor(document: document)
        let view = BoardMacCanvasView(document: document, editor: editor)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return (view, editor, window, session)
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in window: NSWindow, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        // 視圖是翻轉的（y 向下）；視窗座標 y 向上
        let content = window.contentView!.bounds
        return NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: content.height - p.y), modifierFlags: flags,
                                  timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: clicks, pressure: 1)!
    }

    private func click(_ view: BoardMacCanvasView, _ window: NSWindow, _ p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(.leftMouseDown, p, in: window, flags: flags))
        view.mouseUp(with: mouse(.leftMouseUp, p, in: window, flags: flags))
    }

    private func key(_ chars: String, in window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
    }

    /// 把 layer 樹畫進點陣（Core Animation 的合成結果，列 0 = 畫面上方）後取樣
    private func pixel(_ view: NSView, _ x: Int, _ y: Int) throws -> (r: Int, g: Int, b: Int) {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let layer = try #require(view.layer)
        CATransaction.flush()
        // 模擬視窗合成：翻轉的根 layer 放在一般（y 向上）的父 layer 底下，單獨 render 會忽略根 layer 自己的翻轉
        let host = CALayer()
        host.frame = view.bounds
        let originalFrame = layer.frame
        host.addSublayer(layer)
        layer.frame = view.bounds
        host.render(in: ctx)
        layer.removeFromSuperlayer()
        layer.frame = originalFrame
        let data = try #require(ctx.makeImage()?.dataProvider?.data as Data?)
        let i = y * ctx.bytesPerRow + x * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    @Test func rendersUprightAtInitialPlacement() throws {
        let (view, _, _, _) = try setUp()
        // 矩形在螢幕 (42,42)…(242,142)：紅色；翻轉的話會跑到畫面下方
        let inside = try pixel(view, 100, 80)
        #expect(inside.r > 200 && inside.g < 80, "矩形應該在畫面上方，實際 \(inside)")
        let below = try pixel(view, 100, 500)
        #expect(below.r > 200 && below.g > 200 && below.b > 200, "畫面下方應該是白色，實際 \(below)")
    }

    @Test func clickSelectsAndShiftClickToggles() throws {
        var scene = ExcalidrawScene()
        var a = Element.rectangle(x: 100, y: 100, width: 100, height: 100)
        a.raw["backgroundColor"] = "#ffc9c9"
        var b = Element.rectangle(x: 400, y: 100, width: 100, height: 100)
        b.raw["backgroundColor"] = "#ffc9c9"
        scene.insert(a); scene.insert(b)
        let (view, editor, window, _) = try setUp(scene)
        // origin ≈ (58,58)：a 在螢幕 (42,42)…(142,142)，b 在 (342,42)…(442,142)
        click(view, window, CGPoint(x: 90, y: 90))
        #expect(editor.selection == [a.id])
        click(view, window, CGPoint(x: 390, y: 90), flags: .shift)
        #expect(editor.selection == [a.id, b.id])
        click(view, window, CGPoint(x: 390, y: 90), flags: .shift) // 再按一次 = 移除
        #expect(editor.selection == [a.id])
        click(view, window, CGPoint(x: 700, y: 500)) // 空白處
        #expect(editor.selection.isEmpty)
    }

    @Test func dragMovesAndUndoRestores() throws {
        let (view, editor, window, _) = try setUp()
        let id = try #require(editor.document.scene.liveElements.first?.id)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 80), in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 130, y: 100), in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 160, y: 120), in: window))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 160, y: 120), in: window))
        let moved = try #require(editor.document.scene.element(id))
        #expect(moved.x == 160 && moved.y == 140) // 位移 (60, 40)
        #expect(editor.selection == [id])
        view.undo(nil)
        let back = try #require(editor.document.scene.element(id))
        #expect(back.x == 100 && back.y == 100)
    }

    @Test func rectangleToolCreatesByDragging() throws {
        let (view, editor, window, _) = try setUp()
        view.keyDown(with: key("r", in: window))
        #expect(editor.tool == .rectangle)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 300), in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 500, y: 380), in: window))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 500, y: 380), in: window))
        #expect(editor.document.scene.liveElements.count == 2)
        #expect(editor.tool == .select) // 建立後回到選取
        #expect(editor.selection.count == 1)
    }

    @Test func keyboardShortcutsDeleteAndDuplicate() throws {
        let (view, editor, window, _) = try setUp()
        click(view, window, CGPoint(x: 100, y: 80))
        #expect(view.performKeyEquivalent(with: key("d", in: window, flags: .command)) == true)
        #expect(editor.document.scene.liveElements.count == 2)
        view.keyDown(with: key("\u{7f}", in: window))
        #expect(editor.document.scene.liveElements.count == 1)
    }

    @Test func scrollPansAndCommandScrollZoomsAroundCursor() throws {
        let (view, editor, _, _) = try setUp()
        let before = editor.visibleRect
        #expect(before.minX == 58 && before.minY == 58) // 矩形左上角（含線寬）− 40
        // 以游標為中心縮放：游標下的場景點不動
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 40, wheel2: 0, wheel3: 0)!
        cg.flags = .maskCommand
        let event = NSEvent(cgEvent: cg)!
        let cursor = view.convert(event.locationInWindow, from: nil)
        let sceneBefore = CGPoint(x: before.minX + cursor.x / editor.zoom, y: before.minY + cursor.y / editor.zoom)
        view.scrollWheel(with: event)
        #expect(editor.zoom != 1)
        let after = editor.visibleRect
        let sceneAfter = CGPoint(x: after.minX + cursor.x / editor.zoom, y: after.minY + cursor.y / editor.zoom)
        #expect(abs(sceneAfter.x - sceneBefore.x) < 0.5 && abs(sceneAfter.y - sceneBefore.y) < 0.5)
    }

    @Test func saveWritesSceneAfterEdit() throws {
        let (view, editor, window, session) = try setUp()
        click(view, window, CGPoint(x: 100, y: 80))
        editor.duplicateSelection()
        view.saveNow()
        let data = try #require(session.files["board.excalidraw"])
        let saved = try ExcalidrawScene(data: data)
        #expect(saved.liveElements.count == 2)
    }
}
#endif
