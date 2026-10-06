import Foundation
import Testing
@testable import EasyNotesCore

/// A test type for companions: `x.note.ann` is the sidecar of `x.note` (equivalent to the PDF plugin's `.pdf.ink`)
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
        // Companions are indexed as usual (so external edits can be detected) but do not appear in lists or search
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

        // A same name, moving into itself or a subfolder never moves
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

        try mac.move("講義.note", "課程/第一章.note") // Finder changed only the main file
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
        #expect(deleted.map(\.path) == ["講義.note"]) // Companions are not listed
        #expect(try await mac.engine.restore(deleted[0]) == "講義.note")
        #expect(mac.read("講義.note.ann") == "標註\n")
        await mac.sync()
        #expect(await backend.rows.values.allSatisfy { !$0.deleted })
        #expect(await mac.engine.currentStatus.pending == 0)
    }

    @Test func hardDeleteTakesCompanionAlong() async throws {
        let backend = FakeBackend()
        let mac = try Device("Mac", backend: backend), ipad = try Device("iPad", backend: backend)
        try mac.write("PDF\n", "講義.note")
        try mac.write("標註\n", "講義.note.ann")
        try mac.write("別人\n", "其他.note")
        await mac.sync()
        await ipad.sync()

        #expect(try await mac.engine.requestPurge("講義.note") == ["講義.note", "講義.note.ann"])
        try mac.fs.deleteImmediately("講義.note") // Removes the companion too
        #expect(!mac.exists("講義.note.ann"))
        await mac.sync()
        await ipad.sync()

        #expect(try ipad.snapshot() == ["其他.note": "別人\n"])
        let rows = await backend.rows.values
        #expect(rows.filter(\.purged).count == 2)
        #expect(rows.filter { !$0.deleted }.map(\.path) == ["其他.note"])
        #expect(await backend.blobs.count == 1)
    }

    @Test func purgingFromRecentlyDeletedTakesCompanionAndNothingElse() async throws {
        let backend = FakeBackend()
        let mac = try Device("Mac", backend: backend)
        try mac.write("PDF\n", "講義.note")
        try mac.write("標註\n", "講義.note.ann")
        try mac.write("別人\n", "其他.note")
        await mac.sync()
        for path in ["講義.note", "講義.note.ann", "其他.note"] { try mac.delete(path) }
        await mac.sync()

        let deleted = try await mac.engine.recentlyDeleted()
        #expect(deleted.map(\.path).sorted() == ["其他.note", "講義.note"])
        try await mac.engine.purge(try #require(deleted.first { $0.path == "講義.note" }))

        let rows = await backend.rows.values
        #expect(rows.filter(\.purged).count == 2) // Main file and sidecar
        #expect(try await mac.engine.recentlyDeleted().map(\.path) == ["其他.note"])
        #expect(await backend.blobs.count == 1)
    }
}
