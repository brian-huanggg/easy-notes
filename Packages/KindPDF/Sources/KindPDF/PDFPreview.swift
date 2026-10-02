import CoreGraphics
import EasyNotesUI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// PDF 的列表縮圖與嵌入預覽：第 1 頁（不含標註）在背景以 `CGPDFPage` 畫成白底 PNG。
/// 預覽快取依 `.pdf` 的內容 hash，旁檔變動不會讓縮圖失效。`lines` 只放頁數（給卡片右上角）。
struct PDFPreview: DocumentPreviewProvider {
    static let maxPixelSize: CGFloat = 800

    func makePreview(_ data: Data) -> DocumentPreview {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1)
        else { return DocumentPreview() }
        return DocumentPreview(lines: [String(document.numberOfPages)], image: Self.png(page))
    }

    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView {
        let pages = preview.lines.first.flatMap { Int($0) }
        if let image = preview.image {
            return AnyView(PDFThumbnail(png: image, pages: pages, scale: scale))
        }
        return AnyView(ThumbPDF(tint: .red, pages: pages, scale: scale))
    }

    /// 套用頁面 `rotation`，最長邊 `maxPixelSize`
    static func png(_ page: CGPDFPage) -> Data? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        guard rotated.width > 0, rotated.height > 0 else { return nil }
        let scale = maxPixelSize / max(rotated.width, rotated.height)
        let width = max(1, Int((rotated.width * scale).rounded())), height = max(1, Int((rotated.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(target)
        // getDrawingTransform 只會縮小，放大要自己算：先畫到原尺寸的框，再整體縮放
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: rotated), rotate: 0,
                                                 preserveAspectRatio: true))
        ctx.clip(to: box)
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// 設計稿 `C/Thumb PDF` 的版面：灰底上一張紙（第 1 頁的圖），左上類型標記、右上頁數。
/// 依顯示大小在背景解碼 PNG；深色模式不反相，紙張維持白色。
struct PDFThumbnail: View {
    let png: Data
    let pages: Int?
    let scale: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        let s = scale
        GeometryReader { geo in
            let paper = CGSize(width: geo.size.width - 140 * s, height: geo.size.height - 14 * s)
            // 不能用 Group：還沒有圖時 Group 沒有子 view，`.task` 永遠不會執行
            ZStack(alignment: .top) {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3 * s, topTrailingRadius: 3 * s))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 3 * s, topTrailingRadius: 3 * s)
                            .strokeBorder(Palette.borderStrong))
                }
            }
            .frame(width: max(paper.width, 1), height: max(paper.height, 1), alignment: .top)
            .frame(maxWidth: .infinity)
            .padding(.top, 14 * s)
            .task(id: TaskKey(png: png.count, size: paper, scale: displayScale)) {
                let target = Int((max(paper.width, paper.height) * displayScale).rounded(.up))
                let png = png
                image = await Task.detached(priority: .utility) { Self.decode(png, maxPixels: target) }.value
            }
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            Text("PDF")
                .font(.system(size: 9 * s, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6 * s)
                .padding(.vertical, 3 * s)
                .background(RoundedRectangle(cornerRadius: 4 * s).fill(KindTint.red.base))
                .padding(14 * s)
        }
        .overlay(alignment: .topTrailing) {
            if let pages {
                Label("\(pages)", systemImage: "square.on.square")
                    .font(.system(size: 10 * s))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 5 * s)
                    .padding(.vertical, 2 * s)
                    .background(Capsule().fill(Palette.surfaceGlass))
                    .padding(.top, 16 * s)
                    .padding(.trailing, 28 * s)
            }
        }
        .background(Palette.bgHover)
    }

    private struct TaskKey: Hashable {
        var png: Int
        var size: CGSize
        var scale: CGFloat
    }

    nonisolated static func decode(_ png: Data, maxPixels: Int) -> CGImage? {
        guard maxPixels > 0, let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
