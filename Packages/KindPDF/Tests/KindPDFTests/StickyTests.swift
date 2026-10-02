import ExcalidrawKit
import Foundation
import Testing
@testable import KindPDF

/// 5b：便利貼（無外框 rectangle `#ffec99` + `containerId` 文字，字級 14）
struct StickyTests {
    @Test func settingTextCreatesBoundTextThenUpdatesIt() throws {
        var scene = ExcalidrawScene()
        let sticky = Element.stickyNote(x: 10, y: 10, size: PDFStickies.size)
        scene.insert(sticky)

        scene.setStickyText(sticky.id, to: "第一行")
        let text = try #require(scene.liveElements.first { $0.containerId == sticky.id })
        #expect(text.type == .text)
        #expect(text.fontSize == PDFStickies.fontSize)
        #expect(text.originalText == "第一行")
        #expect(scene.stickyIDs(sticky.id) == [sticky.id, text.id])

        scene.setStickyText(sticky.id, to: "改過的文字")
        let texts = scene.liveElements.filter { $0.containerId == sticky.id }
        #expect(texts.count == 1)
        #expect(texts.first?.originalText == "改過的文字")
        #expect(texts.first.map { $0.version > text.version } == true)
    }

    @Test func emptyTextOnNewStickyAddsNothing() {
        var scene = ExcalidrawScene()
        let sticky = Element.stickyNote(x: 0, y: 0, size: PDFStickies.size)
        scene.insert(sticky)
        scene.setStickyText(sticky.id, to: "")
        #expect(scene.liveElements.count == 1)
    }

    @Test func movingStickyMovesItsText() throws {
        var scene = ExcalidrawScene()
        let sticky = Element.stickyNote(x: 0, y: 0, size: PDFStickies.size)
        scene.insert(sticky)
        scene.setStickyText(sticky.id, to: "跟著走")
        let before = try #require(scene.liveElements.first { $0.containerId == sticky.id })
        scene.move([sticky.id], dx: 30, dy: 40)
        let after = try #require(scene.element(before.id))
        #expect(after.x == before.x + 30 && after.y == before.y + 40)
        #expect(scene.without(scene.stickyIDs(sticky.id)).liveElements.isEmpty)
        #expect(scene.only([sticky.id]).liveElements.map(\.id) == [sticky.id])
    }

    @Test func resizingStickyRewrapsText() throws {
        var scene = ExcalidrawScene()
        let sticky = Element.stickyNote(x: 0, y: 0, size: PDFStickies.size)
        scene.insert(sticky)
        scene.setStickyText(sticky.id, to: "一段比較長的便利貼文字，縮小之後應該要換更多行")
        let before = try #require(scene.liveElements.first { $0.containerId == sticky.id })
        scene.resize(sticky.id, to: CGRect(x: 0, y: 0, width: 80, height: 80), from: scene.element(sticky.id))
        let after = try #require(scene.element(before.id))
        #expect(after.text.components(separatedBy: "\n").count > before.text.components(separatedBy: "\n").count)
        #expect(try #require(scene.element(sticky.id)).width == 80)
    }
}

/// 標註改變時只重畫改變的範圍
@MainActor
struct ChangedAreaTests {
    @Test func onlyChangedElementsAreDirty() {
        var scene = ExcalidrawScene()
        let a = Element.stickyNote(x: 0, y: 0, size: 100), b = Element.stickyNote(x: 400, y: 400, size: 100)
        scene.insert(a)
        scene.insert(b)
        #expect(PageOverlayView.changedArea(from: scene, to: scene).isNull)

        var moved = scene
        moved.move([a.id], dx: 50, dy: 0)
        let area = PageOverlayView.changedArea(from: scene, to: moved)
        #expect(area.contains(CGRect(x: 0, y: 0, width: 150, height: 100)))   // 舊位置 + 新位置
        #expect(!area.intersects(CGRect(x: 400, y: 400, width: 100, height: 100))) // b 沒變

        var deleted = scene
        deleted.delete([b.id])
        #expect(PageOverlayView.changedArea(from: scene, to: deleted).contains(CGRect(x: 400, y: 400, width: 100, height: 100)))
    }
}
