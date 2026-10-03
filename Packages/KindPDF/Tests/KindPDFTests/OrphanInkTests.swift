import EasyNotesCore
import Foundation
import Testing
@testable import KindPDF

/// 5a：外部工具改名 PDF、旁檔留在原地 → 開啟時以 `pdfHash` 認領
struct OrphanInkTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "pdf-orphan-\(UUID().uuidString)")

    func vault() throws -> VaultFS {
        VaultFS(root: root, kinds: try KindRegistry([PDFKind.self, PDFInkKind.self]))
    }

    @Test func claimsOrphanWithSameHash() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try vault()
        let pdf = Sample.pdf(pages: 2), other = Sample.pdf(pages: 5)
        let ink = Sample.ink(page: 0, strokes: [Sample.stroke()], into: PDFInk(pdfHash: PDFInk.hash(of: pdf)))
        try fs.write(pdf, to: "課程/第一章.pdf")                       // Finder 把「講義.pdf」改名成這個
        try fs.write(ink.data(), to: "講義.pdf.ink")                    // 主檔已不存在的孤兒
        try fs.write(PDFInk(pdfHash: PDFInk.hash(of: other)).data(), to: "別的.pdf.ink")
        try fs.write(ink.data(), to: "還在.pdf.ink")
        try fs.write(pdf, to: "還在.pdf")                               // 主檔還在：不是孤兒

        #expect(try PDFInk.claimOrphan(for: "課程/第一章.pdf", pdfData: pdf, in: fs) == "講義.pdf.ink")
        #expect(fs.exists("課程/第一章.pdf.ink"))
        #expect(!fs.exists("講義.pdf.ink"))
        #expect(fs.exists("還在.pdf.ink") && fs.exists("別的.pdf.ink"))
        #expect(try PDFInk(data: fs.read("課程/第一章.pdf.ink")).scene(page: 0).inkStrokes.count == 1)
        // 已有旁檔就不再認領
        #expect(try PDFInk.claimOrphan(for: "課程/第一章.pdf", pdfData: pdf, in: fs) == nil)
    }

    @Test func noMatchLeavesEverything() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try vault()
        try fs.write(Sample.pdf(pages: 1), to: "新.pdf")
        try fs.write(PDFInk(pdfHash: "different").data(), to: "舊.pdf.ink")
        #expect(try PDFInk.claimOrphan(for: "新.pdf", pdfData: Sample.pdf(pages: 1), in: fs) == nil)
        #expect(fs.exists("舊.pdf.ink"))
    }
}
