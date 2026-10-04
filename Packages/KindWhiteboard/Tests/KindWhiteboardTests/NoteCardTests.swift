import CoreGraphics
import EasyNotesUI
import Foundation
import Testing
@testable import ExcalidrawKit
@testable import KindWhiteboard

@MainActor
struct NoteCardTests {
    private let path = "board.excalidraw"
    private let preview = DocumentPreview(title: "微積分", lines: ["極限", "導數", "積分"])

    @Test func heightFollowsLineCountWithCap() {
        let none = DocumentPreview(title: "t", lines: [])
        let many = DocumentPreview(title: "t", lines: (0..<20).map(String.init))
        #expect(NoteCardPainter.height(for: none) == NoteCardPainter.minHeight)
        #expect(NoteCardPainter.height(for: preview) == 14 * 2 + 24 + 6 + 3 * 20)
        #expect(NoteCardPainter.height(for: many) == 14 * 2 + 24 + 6 + Double(NoteCardPainter.maxLines) * 20)
    }

    @Test func fitOnlyWhileHeightIsStillTheLastAutoFit() {
        var scene = ExcalidrawScene()
        let id = scene.insertNoteCard(path: "a.md", in: CGRect(x: 0, y: 0, width: 280, height: 160))
        let first = scene.fitNoteCard(id, toHeight: 134)
        #expect(first)
        #expect(scene.element(id)?.height == 134)
        let again = scene.fitNoteCard(id, toHeight: 134) // 沒變
        #expect(!again)
        // 使用者手動改了高度 → 不再自動調整
        scene.mutate(id) { $0.height = 300 }
        let manual = scene.fitNoteCard(id, toHeight: 200)
        #expect(!manual)
        #expect(scene.element(id)?.height == 300)
    }

    @Test func documentFitsCardToPreviewAndSaves() async throws {
        let session = FakeSession()
        var scene = ExcalidrawScene()
        let id = scene.insertNoteCard(path: "a.md", in: CGRect(x: 0, y: 0, width: 280, height: 160))
        session.files[path] = try scene.data()
        session.previews["a.md"] = preview
        let doc = BoardDocument(path: path, session: session)
        var notified = 0
        doc.onExternalChange = { notified += 1 }
        await doc.refreshCardPreviews()
        #expect(doc.cardPreviews["a.md"] == preview)
        #expect(doc.scene.element(id)?.height == NoteCardPainter.height(for: preview))
        #expect(notified == 1)
        let saved = try ExcalidrawScene(data: try #require(session.files[path]))
        #expect(saved.element(id)?.height == NoteCardPainter.height(for: preview))
        // 沒變就不通知
        await doc.refreshCardPreviews()
        #expect(notified == 1)
    }

    @Test func treeHidesTitleTextAndRebuildsWhenPreviewArrives() {
        var scene = ExcalidrawScene()
        let id = scene.insertNoteCard(path: "a.md", in: CGRect(x: 0, y: 0, width: 280, height: 160))
        let title = scene.liveElements.first { $0.containerId == id }!.id
        var previews: [String: DocumentPreview] = [:]
        let tree = BoardLayerTree(drawsFreedraw: true)
        tree.cardPreview = { previews[$0] }
        tree.setScene(scene)
        tree.updateVisible(CGRect(x: -10, y: -10, width: 400, height: 300))
        #expect(tree.layer(for: title)?.isHidden == false)
        let before = tree.layer(for: id)?.sublayers?.count

        previews["a.md"] = preview
        tree.setScene(scene)
        #expect(tree.layer(for: title)?.isHidden == true)
        #expect((tree.layer(for: id)?.sublayers?.count ?? 0) > before ?? 0)
    }
}
