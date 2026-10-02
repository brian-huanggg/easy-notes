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
}
