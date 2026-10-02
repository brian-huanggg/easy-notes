import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import KindPDF

/// 5a：未旋轉的 cropBox 頁面座標（左上、y 向下）⇄ 顯示座標
struct PageGeometryTests {
    let size = CGSize(width: 600, height: 800)

    @Test func rotationIsNormalized() {
        #expect(PDFPageGeometry(size: size, rotation: -90).rotation == 270)
        #expect(PDFPageGeometry(size: size, rotation: 450).rotation == 90)
        #expect(PDFPageGeometry(size: size, rotation: 360).rotation == 0)
    }

    @Test func cornersMapClockwise() {
        // 未旋轉頁面的左上角，順時針轉 90 後在右上角
        let g90 = PDFPageGeometry(size: size, rotation: 90)
        #expect(g90.displaySize == CGSize(width: 800, height: 600))
        #expect(g90.toDisplay(CGPoint(x: 0, y: 0)) == CGPoint(x: 800, y: 0))
        #expect(g90.toDisplay(CGPoint(x: 600, y: 0)) == CGPoint(x: 800, y: 600))
        let g180 = PDFPageGeometry(size: size, rotation: 180)
        #expect(g180.toDisplay(CGPoint(x: 0, y: 0)) == CGPoint(x: 600, y: 800))
        let g270 = PDFPageGeometry(size: size, rotation: 270)
        #expect(g270.toDisplay(CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 600))
        #expect(PDFPageGeometry(size: size, rotation: 0).toDisplay(CGPoint(x: 5, y: 7)) == CGPoint(x: 5, y: 7))
    }

    @Test(arguments: [0, 90, 180, 270])
    func roundTripAndTransformAgree(rotation: Int) {
        let g = PDFPageGeometry(size: size, rotation: rotation)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 123.5, y: 456.25), CGPoint(x: 600, y: 800)] {
            #expect(g.toPage(g.toDisplay(p)) == p)
            let viaTransform = p.applying(g.displayTransform)
            let direct = g.toDisplay(p)
            #expect(abs(viaTransform.x - direct.x) < 1e-9 && abs(viaTransform.y - direct.y) < 1e-9)
        }
        let rect = g.toDisplay(CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(rect.width == (rotation % 180 == 0 ? 100 : 50))
        #expect(CGRect(origin: .zero, size: g.displaySize).contains(rect))
    }

    @Test func pdfSpaceUsesCropBoxOrigin() {
        let crop = CGRect(x: 50, y: 30, width: 500, height: 700)
        let g = PDFPageGeometry(cropBox: crop, rotation: 0)
        #expect(g.size == crop.size)
        #expect(g.toPDFSpace(CGPoint(x: 0, y: 0), cropBox: crop) == CGPoint(x: 50, y: 730))
        #expect(g.toPDFSpace(CGPoint(x: 500, y: 700), cropBox: crop) == CGPoint(x: 550, y: 30))
    }

    @Test func readsCropBoxAndRotationFromPDFPage() throws {
        let doc = try #require(PDFDocument(data: Sample.pdf(pages: 2)))
        let page = try #require(doc.page(at: 1))
        page.rotation = 90
        page.setBounds(CGRect(x: 20, y: 40, width: 400, height: 500), for: .cropBox)
        let g = PDFPageGeometry(page: page)
        #expect(g.rotation == 90)
        #expect(g.size == CGSize(width: 400, height: 500))
        #expect(g.displaySize == CGSize(width: 500, height: 400))
    }
}
