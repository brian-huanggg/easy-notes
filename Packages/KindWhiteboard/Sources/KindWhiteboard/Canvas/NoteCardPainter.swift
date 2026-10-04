import CoreGraphics
import CoreText
import EasyNotesUI
import ExcalidrawKit
import Foundation

/// 筆記卡片的內容（標題 + 前幾行預覽）。卡片高度跟著行數（見 architecture/whiteboard.md「筆記卡片放進白板」），
/// 排版是固定行高，所以高度不需要量測文字。
enum NoteCardPainter {
    static let padding: Double = 14
    static let titleBox: Double = 24
    static let bodyBox: Double = 20
    static let gap: Double = 6
    static let maxLines = 6
    static let minHeight: Double = 64

    static func lines(_ preview: DocumentPreview) -> [String] {
        Array(preview.lines.prefix(maxLines))
    }

    /// 內容需要的卡片高度（畫布座標）
    static func height(for preview: DocumentPreview) -> Double {
        let n = lines(preview).count
        return max(minHeight, padding * 2 + titleBox + (n > 0 ? gap + Double(n) * bodyBox : 0))
    }

    /// 畫在卡片矩形內（y 向下的座標，原點是 `rect` 左上角）
    static func draw(name: String, preview: DocumentPreview, in rect: CGRect, ctx: CGContext) {
        let width = rect.width - padding * 2
        var y = rect.minY + padding
        drawLine(preview.title ?? name, size: 18, color: CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1),
                 x: rect.minX + padding, top: y, box: titleBox, width: width, ctx: ctx)
        y += titleBox + gap
        let body = CGColor(srgbRed: 0.29, green: 0.31, blue: 0.34, alpha: 1)
        for text in lines(preview) {
            drawLine(text, size: 14, color: body, x: rect.minX + padding, top: y, box: bodyBox, width: width, ctx: ctx)
            y += bodyBox
        }
    }

    private static func drawLine(_ text: String, size: Double, color: CGColor, x: Double, top: Double, box: Double,
                                 width: Double, ctx: CGContext) {
        let font = TextLayout.font(size: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ]
        func line(_ s: String) -> CTLine { CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes)) }
        var ct = line(text)
        if CTLineGetTypographicBounds(ct, nil, nil, nil) > width, let truncated = CTLineCreateTruncatedLine(ct, width, .end, line("…")) {
            ct = truncated
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: top + box / 2 + (ascent - descent) / 2)
        CTLineDraw(ct, ctx)
        ctx.restoreGState()
    }
}
