import EasyNotesCore
import EasyNotesUI
import ExcalidrawKit
import Foundation
import Testing
@testable import KindPDF

/// 5b：開啟中的 PDF（`pdfHash` 檢查、「保留標註」、第一次寫入旁檔、外部變動合併、孤兒旁檔認領）
@MainActor
struct PDFInkDocumentTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "pdf-doc-\(UUID().uuidString)")

    /// 等背景算完 `pdfHash`
    func opened(_ path: String, _ session: DiskSession) async throws -> PDFInkDocument {
        let doc = PDFInkDocument(path: path, session: session)
        for _ in 0..<200 where doc.pdfHash == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(doc.pdfHash != nil)
        return doc
    }

    @Test func mismatchedHashShowsWarningUntilKept() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try DiskSession(root: root)
        let pdf = Sample.pdf()
        try session.vault.write(pdf, to: "講義.pdf")
        try session.vault.write(Sample.ink(page: 0, strokes: [Sample.stroke()], into: PDFInk(pdfHash: "old")).data(),
                                to: "講義.pdf.ink")

        let doc = try await opened("講義.pdf", session)
        #expect(doc.hashMismatch)
        #expect(doc.scene(page: 0).inkStrokes.count == 1) // 仍依頁碼顯示

        doc.keepAnnotations()
        #expect(!doc.hashMismatch)
        let saved = try PDFInk(data: session.readData("講義.pdf.ink"))
        #expect(saved.pdfHash == PDFInk.hash(of: pdf))
        #expect(saved.elements(page: 0).count == 1)
    }

    @Test func matchingOrMissingHashHasNoWarning() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try DiskSession(root: root)
        let pdf = Sample.pdf()
        try session.vault.write(pdf, to: "a.pdf")
        try session.vault.write(PDFInk(pdfHash: PDFInk.hash(of: pdf)).data(), to: "a.pdf.ink")
        try session.vault.write(pdf, to: "b.pdf")
        try session.vault.write(PDFInk(pdfHash: "").data(), to: "b.pdf.ink")

        #expect(try await !opened("a.pdf", session).hashMismatch)
        #expect(try await !opened("b.pdf", session).hashMismatch)
    }

    @Test func firstCommitCreatesInkWithCurrentHash() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try DiskSession(root: root)
        let pdf = Sample.pdf()
        try session.vault.write(pdf, to: "新.pdf")

        let doc = try await opened("新.pdf", session)
        #expect(!session.vault.exists("新.pdf.ink")) // 開啟不建立旁檔
        doc.edit(page: 1) { $0.insert(Element.stickyNote(x: 10, y: 10, size: 160)) }
        doc.commit()
        let saved = try PDFInk(data: session.readData("新.pdf.ink"))
        #expect(saved.pdfHash == PDFInk.hash(of: pdf))
        #expect(saved.pageIndexes == [1])
    }

    @Test func externalInkChangeMergesAndNotifies() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try DiskSession(root: root)
        let pdf = Sample.pdf()
        let hash = PDFInk.hash(of: pdf)
        try session.vault.write(pdf, to: "x.pdf")
        try session.vault.write(Sample.ink(page: 0, strokes: [Sample.stroke(x: 10)], into: PDFInk(pdfHash: hash)).data(),
                                to: "x.pdf.ink")
        let doc = try await opened("x.pdf", session)
        var notified: Set<Int>?? = .none
        doc.onInkChange = { notified = .some($0) }
        doc.edit(page: 2) { $0.insert(Element.stickyNote(x: 0, y: 0, size: 160)) } // 本機未存的修改
        notified = .none

        let remote = Sample.ink(page: 1, strokes: [Sample.stroke(x: 50)], into: PDFInk(pdfHash: hash))
        doc.externalChange(path: "x.pdf.ink", data: try remote.data())

        #expect(notified == .some(nil))
        #expect(doc.scene(page: 1).inkStrokes.count == 1)
        #expect(doc.scene(page: 2).liveElements.count == 1)
        // 合併後與遠端不同（本機多了第 2 頁）→ 寫回
        #expect(try PDFInk(data: session.readData("x.pdf.ink")).pageIndexes.contains(2))
    }

    @Test func claimsOrphanOnOpenAndNotifiesMove() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try DiskSession(root: root)
        let pdf = Sample.pdf()
        try session.vault.write(pdf, to: "新名字.pdf")
        try session.vault.write(Sample.ink(page: 0, strokes: [Sample.stroke()],
                                           into: PDFInk(pdfHash: PDFInk.hash(of: pdf))).data(), to: "舊名字.pdf.ink")

        let doc = try await opened("新名字.pdf", session)
        #expect(session.moves.map(\.from) == ["舊名字.pdf.ink"])
        #expect(session.moves.map(\.to) == ["新名字.pdf.ink"])
        #expect(doc.scene(page: 0).inkStrokes.count == 1)
        #expect(!doc.hashMismatch)
    }
}

/// 讀寫真的檔案（`PDFInkDocument` 在背景用 `vault` 讀 PDF）
@MainActor
final class DiskSession: DocumentSession {
    let vault: VaultFS
    private(set) var moves: [(from: String, to: String)] = []
    var index: VaultIndex? { nil }
    var resourceReader: @Sendable (String) async -> Data? { { _ in nil } }

    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = VaultFS(root: root, kinds: try KindRegistry([PDFKind.self, PDFInkKind.self]))
    }

    func readData(_ path: String) -> Data { (try? vault.read(path)) ?? Data() }
    func write(_ data: Data, to path: String) { try? vault.write(data, to: path) }
    func fileMoved(from: String, to: String) { moves.append((from, to)) }
    func openLink(_ target: String) {}
    func search(_ query: String) {}
    func modified(_ path: String) -> Date? { nil }
    func importAttachment(_ url: URL) async -> String? { nil }
    func open(_ path: String, line: Int?) {}
    func metaChanged() {}
}
