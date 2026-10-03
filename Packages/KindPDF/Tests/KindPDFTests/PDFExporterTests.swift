import CoreGraphics
import ExcalidrawKit
import Foundation
import PDFKit
import Testing
@testable import KindPDF

@Suite struct PDFExporterTests {
    @Test func exportedPathNeverOverwrites() {
        var existing: Set<String> = []
        #expect(PDFExporter.exportedPath(forPDF: "課本/微積分.pdf", exists: existing.contains) == "課本/微積分（標註）.pdf")
        existing = ["課本/微積分（標註）.pdf", "課本/微積分（標註 2）.pdf"]
        #expect(PDFExporter.exportedPath(forPDF: "課本/微積分.pdf", exists: existing.contains) == "課本/微積分（標註 3）.pdf")
        #expect(PDFExporter.exportedPath(forPDF: "a.pdf", exists: { _ in false }) == "a（標註）.pdf")
    }

    /// 旋轉頁輸出為旋轉後的尺寸；筆畫畫在顯示座標對應的位置（第 2 頁 rotation 90）；原始 PDF 不變
    @Test func flattensStrokesOnRotatedPages() throws {
        let dir = try temporaryDirectory()
        let source = dir.appending(path: "in.pdf"), output = dir.appending(path: "out.pdf")
        let original = try rotatedSample()
        try original.write(to: source)

        let stroke = InkStroke(ink: "com.apple.ink.pen", color: "#1e1e1e", opacity: 1,
                               points: (0..<20).map { InkStroke.Point(x: 300 + Double($0) * 5, y: 400, size: 8) })
        var ink = Sample.ink(page: 0, strokes: [stroke])
        ink = Sample.ink(page: 1, strokes: [stroke], into: ink)

        var reports: [Int] = []
        try PDFExporter.export(pdf: source, ink: ink, to: output) { done, _ in reports.append(done); return true }
        #expect(reports == [0, 1, 2, 3])
        #expect(try Data(contentsOf: source) == original)

        let doc = try #require(CGPDFDocument(output as CFURL))
        #expect(doc.numberOfPages == 3)
        let portrait = try #require(doc.page(at: 1)), rotated = try #require(doc.page(at: 2))
        #expect(portrait.getBoxRect(.mediaBox).size == CGSize(width: 612, height: 792))
        #expect(rotated.getBoxRect(.mediaBox).size == CGSize(width: 792, height: 612))
        #expect(rotated.rotationAngle == 0)

        let mid = CGPoint(x: 350, y: 400)
        #expect(try darkness(of: portrait, at: mid) > 0.5)
        let geometry = PDFPageGeometry(size: CGSize(width: 612, height: 792), rotation: 90)
        #expect(try darkness(of: rotated, at: geometry.toDisplay(mid)) > 0.5)
        #expect(try darkness(of: rotated, at: mid) < 0.1)
        // 沒有標註的頁只有原頁面
        #expect(try darkness(of: try #require(doc.page(at: 3)), at: mid) < 0.1)
    }

    /// 便利貼以向量文字畫出：其他閱讀器可以選取、搜尋
    @Test func stickyTextIsVector() throws {
        let dir = try temporaryDirectory()
        let source = dir.appending(path: "in.pdf"), output = dir.appending(path: "out.pdf")
        try Sample.pdf(pages: 1).write(to: source)
        var ink = PDFInk(pdfHash: "abc")
        var scene = ink.scene(page: 0)
        let sticky = Element.stickyNote(x: 100, y: 100, size: PDFStickies.size)
        scene.insert(sticky)
        scene.setStickyText(sticky.id, to: "期中考範圍")
        ink.setScene(scene, page: 0)

        try PDFExporter.export(pdf: source, ink: ink, to: output)
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("期中考範圍"))
    }

    @Test func cancelLeavesNoFile() throws {
        let dir = try temporaryDirectory()
        let source = dir.appending(path: "in.pdf"), output = dir.appending(path: "out.pdf")
        try Sample.pdf(pages: 5).write(to: source)
        #expect(throws: PDFExporter.ExportError.self) {
            try PDFExporter.export(pdf: source, ink: PDFInk(), to: output) { done, _ in done < 2 }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    // MARK: 輔助

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 3 頁，第 2 頁 rotation 90
    private func rotatedSample() throws -> Data {
        let doc = try #require(PDFDocument(data: Sample.pdf(pages: 3)))
        doc.page(at: 1)?.rotation = 90
        return try #require(doc.dataRepresentation())
    }

    /// 輸出頁（未旋轉）在顯示座標 `point`（左上、y 向下）附近 3×3 的最大暗度（0 白 – 1 黑）
    private func darkness(of page: CGPDFPage, at point: CGPoint) throws -> Double {
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width), height = Int(box.height)
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.drawPDFPage(page)
        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        var darkest = 0.0
        for dy in -1...1 {
            for dx in -1...1 {
                let x = Int(point.x) + dx, y = Int(point.y) + dy // 記憶體第 0 列是頂端
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                darkest = max(darkest, 1 - Double(pixels[y * width + x]) / 255)
            }
        }
        return darkest
    }
}
