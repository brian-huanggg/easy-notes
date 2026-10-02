import Foundation
import Testing
import EasyNotesCore
@testable import ExcalidrawKit
@testable import KindWhiteboard

/// 4a：開啟中的白板接收外部變動
@MainActor
struct BoardDocumentTests {
    let path = "board.excalidraw"

    func seeded() throws -> FakeSession {
        let session = FakeSession()
        var scene = ExcalidrawScene()
        scene.insert(Element.rectangle(x: 0, y: 0, width: 10, height: 10))
        session.files[path] = try scene.data()
        return session
    }

    @Test func externalElementSurvivesLaterSave() throws {
        let session = try seeded()
        let controller = WhiteboardController()
        let doc = controller.open(path, session: session)

        // Claude Code 在磁碟上加了一個文字元素
        var disk = try ExcalidrawScene(data: session.files[path]!)
        let added = Element.text("外部加入", x: 50, y: 50)
        disk.insert(added)
        var notified = false
        doc.onExternalChange = { notified = true }
        controller.externalChange(path: path, data: try disk.data())
        #expect(notified)
        #expect(doc.scene.element(added.id) != nil)
        #expect(session.writes.isEmpty) // 合併結果與磁碟相同：不寫回

        // 之後編輯器存檔（例如畫了一筆），外部加入的元素仍在
        doc.commit { $0.replaceInk(with: [InkRoundTripTests.sampleStroke()]) }
        let saved = try ExcalidrawScene(data: try #require(session.writes.last?.data))
        #expect(saved.element(added.id) != nil)
        #expect(saved.inkStrokes.count == 1)
    }

    @Test func unsavedEditorContentIsMergedNotLost() throws {
        let session = try seeded()
        let controller = WhiteboardController()
        let doc = controller.open(path, session: session)
        // 模擬畫布上還沒存的筆畫：flush 時才寫進場景
        doc.flushHandler = { [doc] in doc.commit { $0.replaceInk(with: [InkRoundTripTests.sampleStroke()]) } }

        var disk = try ExcalidrawScene(data: session.files[path]!)
        disk.insert(Element.ellipse(x: 0, y: 0, width: 5, height: 5))
        controller.externalChange(path: path, data: try disk.data())

        #expect(doc.scene.inkStrokes.count == 1)
        #expect(doc.scene.liveElements.count == 3)
        // 本地有、磁碟沒有的筆畫要寫回
        let last = try ExcalidrawScene(data: try #require(session.writes.last?.data))
        #expect(last.liveElements.count == 3)
    }

    @Test func ownWritesAreIgnoredAndFlushSaves() async throws {
        let session = try seeded()
        let controller = WhiteboardController()
        let doc = controller.open(path, session: session)
        #expect(controller.open(path, session: session) === doc)

        var saved = false
        doc.flushHandler = { saved = true }
        await controller.flush()
        #expect(saved)

        doc.commit { $0.insert(Element.rectangle(x: 1, y: 1, width: 1, height: 1)) }
        let writes = session.writes.count
        var notified = false
        doc.onExternalChange = { notified = true }
        controller.externalChange(path: path, data: session.files[path]!) // 自己剛寫的內容回來
        #expect(!notified)
        #expect(session.writes.count == writes)

        controller.close(path: path)
        controller.externalChange(path: path, data: Data()) // 已關閉：不處理
        #expect(controller.open(path, session: session) !== doc)
    }
}
