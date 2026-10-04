import Foundation
import Testing
@testable import EasyNotesCore

/// 伴隨檔的測試類型：`x.note.ann` 是 `x.note` 的旁檔（等同 PDF 外掛的 `.pdf.ink`）
enum AnnotationKind: DocumentKind {
    static let id = "annotation"
    static let fileExtensions = ["note.ann"]
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry {
        IndexEntry(title: fileName, plainText: String(decoding: data, as: UTF8.self))
    }
    static func companionOf(_ path: String) -> String? {
        path.hasSuffix(".note.ann") ? String(path.dropLast(4)) : nil
    }
}

struct CompanionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "companion-\(UUID().uuidString)")

    func vault() throws -> VaultFS {
        VaultFS(root: root, kinds: try KindRegistry([NoteKind.self, AnnotationKind.self]))
    }

    @Test func registryMapsCompanionToMainFile() throws {
        let kinds = try KindRegistry([NoteKind.self, AnnotationKind.self])
        #expect(kinds.mainFile(ofCompanion: "a/講義.note.ann") == "a/講義.note")
        #expect(kinds.mainFile(ofCompanion: "a/講義.note") == nil)
        #expect(!kinds.isCompanion("講義.note"))
        #expect(kinds.companionPath("a/講義.note.ann", from: "a/講義.note", to: "b/第一章.note") == "b/第一章.note.ann")
        #expect(kinds.companionPath("a/其他.note.ann", from: "a/講義.note", to: "b/第一章.note") == nil)
        #expect(NoteKind.companionOf("a.note") == nil)
    }

    @Test func treeAndSearchHideCompanions() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try vault()
        try fs.write(Data("光合作用\n".utf8), to: "生物/講義.note")
        try fs.write(Data("光合作用的標註\n".utf8), to: "生物/講義.note.ann")

        #expect(try fs.allFiles().map(\.path) == ["生物/講義.note"])
        #expect(try fs.allFiles(includingCompanions: true).map(\.path).sorted() == ["生物/講義.note", "生物/講義.note.ann"])
        #expect(try fs.search("標註").isEmpty)

        let index = try VaultIndex(fs: fs)
        // 伴隨檔照常索引（外部修改才偵測得到），但不出現在列表與搜尋
        #expect(try await index.sync() == ["生物/講義.note", "生物/講義.note.ann"])
        #expect(try await index.files().map(\.path) == ["生物/講義.note"])
        #expect(try await index.search("講義").map(\.path) == ["生物/講義.note"])
        #expect(try await index.search("光合作用的標註").isEmpty)
    }

    @Test func renameMovesCompanion() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try vault()
        try fs.write(Data("內容".utf8), to: "講義.note")
        try fs.write(Data("標註".utf8), to: "講義.note.ann")
        try fs.write(Data("別人的".utf8), to: "講義2.note.ann")
        #expect(fs.companions(of: "講義.note") == ["講義.note.ann"])
        #expect(fs.companionMoves(from: "講義.note", to: "第一章.note").map(\.to) == ["第一章.note.ann"])

        #expect(try fs.rename("講義.note", to: "第一章.note") == "第一章.note")
        #expect(try fs.read("第一章.note.ann") == Data("標註".utf8))
        #expect(!fs.exists("講義.note.ann"))
        #expect(fs.exists("講義2.note.ann"))
    }

    @Test func moveToFolderMovesCompanionAndRefusesConflicts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try vault()
        try fs.write(Data("內容".utf8), to: "講義.note")
        try fs.write(Data("標註".utf8), to: "講義.note.ann")
        try fs.write(Data("舊的".utf8), to: "存檔/講義.note")
        _ = try fs.createFolder(named: "課程")
        _ = try fs.createFolder(named: "第一章", in: "課程")

        #expect(try fs.move("講義.note", toFolder: "課程/第一章") == "課程/第一章/講義.note")
        #expect(try fs.read("課程/第一章/講義.note.ann") == Data("標註".utf8))
        #expect(!fs.exists("講義.note") && !fs.exists("講義.note.ann"))

        // 同名、搬進自己或子資料夾都不搬
        #expect(throws: (any Error).self) { try fs.move("課程/第一章/講義.note", toFolder: "存檔") }
        #expect(throws: (any Error).self) { try fs.move("課程", toFolder: "課程/第一章") }
        #expect(throws: (any Error).self) { try fs.move("課程", toFolder: "課程") }
        #expect(fs.exists("課程/第一章/講義.note"))

        #expect(try fs.move("課程/第一章", toFolder: "") == "第一章")
        #expect(fs.exists("第一章/講義.note.ann"))
    }

    @Test func externalRenameMovesCompanionAndKeepsFileID() async throws {
        let backend = FakeBackend()
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("PDF\n", "講義.note")
        try mac.write("標註\n", "講義.note.ann")
        await mac.sync()
        await ipad.sync()
        let ids = await Set(backend.rows.keys)

        try mac.move("講義.note", "課程/第一章.note") // Finder 只改了主檔
        await mac.sync()
        #expect(!mac.exists("講義.note.ann"))
        #expect(mac.read("課程/第一章.note.ann") == "標註\n")
        #expect(await Set(backend.rows.keys) == ids)
        #expect(await backend.rows.values.map(\.path).sorted() == ["課程/第一章.note", "課程/第一章.note.ann"])

        await ipad.sync()
        #expect(try ipad.snapshot() == ["課程/第一章.note": "PDF\n", "課程/第一章.note.ann": "標註\n"])
    }

    @Test func restoringMainFileRestoresCompanion() async throws {
        let backend = FakeBackend()
        let mac = try Device("Mac", backend: backend)
        try mac.write("PDF\n", "講義.note")
        try mac.write("標註\n", "講義.note.ann")
        await mac.sync()
        try mac.delete("講義.note")
        try mac.delete("講義.note.ann")
        await mac.sync()

        let deleted = try await mac.engine.recentlyDeleted()
        #expect(deleted.map(\.path) == ["講義.note"]) // 伴隨檔不列出
        #expect(try await mac.engine.restore(deleted[0]) == "講義.note")
        #expect(mac.read("講義.note.ann") == "標註\n")
        await mac.sync()
        #expect(await backend.rows.values.allSatisfy { !$0.deleted })
        #expect(await mac.engine.currentStatus.pending == 0)
    }
}
