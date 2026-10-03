import CoreGraphics
import CoreText
import EasyNotesUI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 表格的列表縮圖與嵌入預覽：前幾列 × 前幾欄在背景以 CoreGraphics 畫成 PNG（設計稿 `C/Thumb CSV`），
/// 背景透明、淺色配色，深色模式在顯示端反相（與白板相同，`![[x.csv]]` 經 `embed://` 用同一張圖）。
/// 第一列一律畫成標題列（預覽只拿得到主檔內容，不讀顯示設定旁檔）。`lines` 放第一列的前幾格，沒有圖時當欄名。
struct SheetPreview: DocumentPreviewProvider {
    /// 依註冊的類型（CSV / TSV）
    let delimiter: UInt8

    static let maxRows = 8
    static let maxColumns = 6
    /// 每個 pt 畫幾個 pixel
    static let pixelScale: CGFloat = 2

    // 版面（pt），與設計稿相同：標題列 22、資料列 18、字級 8.5
    static let headerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 18
    static let fontSize: CGFloat = 8.5
    static let cellPadding: CGFloat = 8
    static let minColumnWidth: CGFloat = 44
    static let maxColumnWidth: CGFloat = 120

    // 淺色配色（深色由顯示端反相）：`type-csv`、`type-csv-soft`、`text-body`、`border`
    static let tintBase = KindTint.green.base.light
    static let tintSoft = KindTint.green.soft.light
    static let textColor = Palette.textBody.light
    static let lineColor = Palette.border.light

    func makePreview(_ data: Data) -> DocumentPreview {
        let sheet = SheetDocument(data: data, delimiter: delimiter)
        let cells = sheet.records.prefix(Self.maxRows).map { Array($0.fields.prefix(Self.maxColumns)) }
        guard cells.contains(where: { $0.contains { !$0.isEmpty } }) else { return DocumentPreview() }
        return DocumentPreview(lines: Array(cells[0].prefix(4)), image: Self.png(cells))
    }

    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView {
        if let image = preview.image {
            return AnyView(SheetThumbnail(png: image, scale: scale))
        }
        let columns = preview.lines.isEmpty ? ["A", "B", "C", "D"] : preview.lines
        return AnyView(ThumbTable(tint: .green, columns: columns, scale: scale))
    }

    // MARK: 繪製

    static func png(_ cells: [[String]]) -> Data? {
        let columnCount = cells.map(\.count).max() ?? 0
        guard columnCount > 0 else { return nil }
        let regular = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(regular, fontSize, nil, .traitBold, .traitBold) ?? regular
        let text = color(textColor), tint = color(tintBase)

        // 每格的文字只取第一行；欄寬依內容，限制在 min…max
        let lines: [[CTLine]] = cells.enumerated().map { r, row in
            (0..<columnCount).map { c in
                let value = c < row.count ? row[c] : ""
                let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return line(firstLine, font: r == 0 ? bold : regular, color: r == 0 ? tint : text)
            }
        }
        let widths: [CGFloat] = (0..<columnCount).map { c in
            let content = lines.map { CGFloat(CTLineGetTypographicBounds($0[c], nil, nil, nil)) }.max() ?? 0
            return min(max(content + cellPadding * 2, minColumnWidth), maxColumnWidth)
        }
        let size = CGSize(width: widths.reduce(0, +), height: headerHeight + rowHeight * CGFloat(cells.count - 1))
        let pixelWidth = Int((size.width * pixelScale).rounded(.up)), pixelHeight = Int((size.height * pixelScale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 左上為原點，y 向下；文字矩陣再翻回來
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: pixelScale, y: -pixelScale)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        ctx.setFillColor(color(tintSoft))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: headerHeight))

        var y: CGFloat = 0
        for (r, row) in lines.enumerated() {
            let height = r == 0 ? headerHeight : rowHeight
            var x: CGFloat = 0
            for (c, cell) in row.enumerated() {
                let available = widths[c] - cellPadding * 2
                let fitted = truncated(cell, width: available, font: r == 0 ? bold : regular, color: r == 0 ? tint : text)
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(fitted, &ascent, &descent, nil)
                ctx.textPosition = CGPoint(x: x + cellPadding, y: y + (height + ascent - descent) / 2)
                ctx.saveGState()
                ctx.clip(to: CGRect(x: x, y: y, width: widths[c], height: height))
                CTLineDraw(fitted, ctx)
                ctx.restoreGState()
                x += widths[c]
            }
            y += height
        }

        // 格線：欄之間的直線、每列底下的橫線（與設計稿相同，外框不畫）
        ctx.setStrokeColor(color(lineColor))
        ctx.setLineWidth(1 / pixelScale)
        let half = 0.5 / pixelScale
        var x: CGFloat = 0
        for width in widths.dropLast() {
            x += width
            ctx.move(to: CGPoint(x: x - half, y: 0))
            ctx.addLine(to: CGPoint(x: x - half, y: size.height))
        }
        y = 0
        for r in 0..<cells.count - 1 {
            y += r == 0 ? headerHeight : rowHeight
            ctx.move(to: CGPoint(x: 0, y: y - half))
            ctx.addLine(to: CGPoint(x: size.width, y: y - half))
        }
        ctx.strokePath()

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func line(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    private static func truncated(_ line: CTLine, width: CGFloat, font: CTFont, color: CGColor) -> CTLine {
        guard CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > width else { return line }
        return CTLineCreateTruncatedLine(line, Double(width), .end, Self.line("…", font: font, color: color)) ?? line
    }

    /// `#RRGGBB`
    static func color(_ hex: String) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// 卡片縮圖：表格以原本大小（乘上卡片的 `scale`）靠左上擺放、超出的部分裁掉，與設計稿 `C/Thumb CSV` 相同。
/// 深色模式反相並轉回色相（同白板與 md 嵌入的 CSS `invert(93%) hue-rotate(180deg)`）
struct SheetThumbnail: View {
    let png: Data
    let scale: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: CGImage?

    var body: some View {
        // 不能用 Group：還沒有圖時 Group 沒有子 view，`.task` 永遠不會執行
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: SheetPreview.pixelScale / scale)
                    .modifier(DarkInvert(enabled: colorScheme == .dark))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Palette.bgCanvas)
        .task(id: png.count) {
            let png = png
            image = await Task.detached(priority: .utility) { Self.decode(png) }.value
        }
    }

    nonisolated static func decode(_ png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// CSS 的 `invert(93%) hue-rotate(180deg)`：黑字變淺、彩色維持原本的色相（與白板外掛相同；外掛之間不互相 import）
private struct DarkInvert: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.colorInvert().hueRotation(.degrees(180)).brightness(-0.04)
        } else {
            content
        }
    }
}
