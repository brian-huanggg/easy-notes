import CoreGraphics
import ExcalidrawKit
import Foundation
@testable import KindPDF

enum Sample {
    /// `count` 頁的 PDF；`rotation` 設在第 2 頁，`cropBox` 設在第 1 頁（測試座標換算）
    static func pdf(pages count: Int = 3, size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for i in 0..<count {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(gray: CGFloat(i) / CGFloat(max(count, 1)), alpha: 1)
            ctx.fill(CGRect(x: 36, y: 36, width: 100, height: 100))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    static func stroke(x: Double = 10, ink: String = "com.apple.ink.pen", opacity: Double = 1) -> InkStroke {
        InkStroke(ink: ink, color: "#1e1e1e", opacity: opacity,
                  points: (0..<5).map { InkStroke.Point(x: x + Double($0) * 4, y: 20 + Double($0)) })
    }

    static func ink(page: Int, strokes: [InkStroke], into ink: PDFInk = PDFInk(pdfHash: "abc")) -> PDFInk {
        var ink = ink
        var scene = ink.scene(page: page)
        scene.replaceInk(with: scene.inkStrokes + strokes)
        ink.setScene(scene, page: page)
        return ink
    }
}
