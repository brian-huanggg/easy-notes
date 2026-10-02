import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 白板的 CoreGraphics 渲染器：不依賴 UIKit / AppKit，可在背景執行緒使用。
/// 列表縮圖、`![[x.excalidraw]]` 嵌入與 Mac 檢視共用；依檔案順序繪製（手寫與圖形交錯）。
/// 不模擬 rough.js 的手繪風格：`roughness`、`fillStyle`、`fontFamily` 不影響畫面，一律乾淨線條、實心填色、系統字型。
public final class SceneRenderer: @unchecked Sendable {
    /// 未刪除的元素，依渲染順序
    public let elements: [Element]
    /// `appState.viewBackgroundColor`；nil = 透明
    public let background: CGColor?
    private let files: [String: Any]
    private let byID: [String: Element]
    private let boundsCache: [CGRect]

    /// 解碼過的圖片（依 fileId 與像素大小）；Mac 檢視重畫時不必重新解碼
    private let imageCache = NSCache<NSString, CGImage>()

    /// `transparentDefaultBackground`：白色（預設）背景改為透明，讓縮圖與嵌入融入卡片底色、深色模式可以反相；
    /// 使用者自訂的背景色仍然畫出來
    public init(scene: ExcalidrawScene, transparentDefaultBackground: Bool = false) {
        elements = scene.liveElements
        files = scene.raw["files"] as? [String: Any] ?? [:]
        byID = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        boundsCache = elements.map(ElementGeometry.bounds)
        let bg = (scene.raw["appState"] as? [String: Any])?["viewBackgroundColor"] as? String
        let color = SceneColor.parse(bg ?? "#ffffff")
        background = transparentDefaultBackground && color.map(SceneColor.isWhite) ?? true ? nil : color
        imageCache.countLimit = 64
    }

    /// 所有元素的範圍；空白板為 nil
    public var contentBounds: CGRect? {
        boundsCache.reduce(nil) { acc, r in acc.map { $0.union(r) } ?? r }
    }

    // MARK: 輸出圖片

    /// 把整個白板畫成圖片：最長邊不超過 `maxPixelSize`、倍率不超過 `maxScale`。空白板回傳 nil
    public func makeImage(maxPixelSize: Int = 1600, maxScale: CGFloat = 2, padding: CGFloat = 16) -> CGImage? {
        guard let content = contentBounds else { return nil }
        let area = content.insetBy(dx: -padding, dy: -padding)
        let scale = min(maxScale, CGFloat(maxPixelSize) / max(area.width, area.height, 1))
        let width = max(1, Int((area.width * scale).rounded(.up))), height = max(1, Int((area.height * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 畫布座標 y 向下
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        draw(in: ctx, visible: area, pixelScale: scale)
        return ctx.makeImage()
    }

    public func pngData(maxPixelSize: Int = 1600, maxScale: CGFloat = 2) -> Data? {
        guard let image = makeImage(maxPixelSize: maxPixelSize, maxScale: maxScale) else { return nil }
        return Self.png(image)
    }

    static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: 繪製

    /// 在已設定成畫布座標（y 向下）的 `ctx` 上繪製。只畫與 `visible` 相交的元素；
    /// `pixelScale` = 每個畫布單位的像素數，決定圖片解碼的大小。不畫背景。
    public func draw(in ctx: CGContext, visible: CGRect? = nil, pixelScale: CGFloat = 1) {
        for (i, el) in elements.enumerated() {
            if let visible, !boundsCache[i].intersects(visible) { continue }
            // frame 內的元素依 frame 範圍裁切
            let frame = el.frameId.flatMap { byID[$0] }.flatMap { $0.type == .frame ? $0 : nil }
            ctx.saveGState()
            if let frame { ctx.clip(to: frame.rect.standardized) }
            draw(el, in: ctx, pixelScale: pixelScale)
            ctx.restoreGState()
        }
    }

    private func draw(_ el: Element, in ctx: CGContext, pixelScale: CGFloat) {
        let opacity = ((el.raw["opacity"] as? NSNumber)?.doubleValue ?? 100) / 100
        guard opacity > 0 else { return }
        ctx.concatenate(ElementGeometry.rotation(el))
        // 半透明：整個元素合成後才套用透明度，重疊的部分（手寫線段、箭頭頭部）不會變深
        let layered = opacity < 1
        if layered {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        switch el.type {
        case .rectangle, .diamond, .ellipse: drawShape(el, in: ctx)
        case .line, .arrow: drawLinear(el, in: ctx)
        case .freedraw: drawFreedraw(el, in: ctx)
        case .text: drawText(el, in: ctx)
        case .image: drawImage(el, in: ctx, pixelScale: pixelScale)
        case .frame: drawFrame(el, in: ctx)
        case .unknown(let type): drawPlaceholder(el, title: placeholderTitle(el, type: type), in: ctx)
        }
        if layered { ctx.endTransparencyLayer() }
    }

    // MARK: 形狀

    private func drawShape(_ el: Element, in ctx: CGContext) {
        let path = ElementGeometry.outline(el)
        if let fill = color(el, "backgroundColor") {
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        stroke(path, el, in: ctx, join: .miter)
    }

    private func drawLinear(_ el: Element, in ctx: CGContext) {
        let path = ElementGeometry.linePath(el)
        if ElementGeometry.isClosedLine(el), let fill = color(el, "backgroundColor") {
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        stroke(path, el, in: ctx, join: .round)
        guard let strokeColor = color(el, "strokeColor") else { return }
        // 箭頭頭部一律實線
        ctx.setStrokeColor(strokeColor)
        ctx.setFillColor(strokeColor)
        ctx.setLineWidth(ElementGeometry.strokeWidth(el))
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for head in ElementGeometry.arrowheads(el) {
            ctx.addPath(head.path)
            ctx.drawPath(using: head.fill ? .fillStroke : .stroke)
        }
    }

    private func stroke(_ path: CGPath, _ el: Element, in ctx: CGContext, join: CGLineJoin) {
        let width = ElementGeometry.strokeWidth(el)
        guard width > 0, let strokeColor = color(el, "strokeColor") else { return }
        ctx.addPath(path)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(width)
        ctx.setLineJoin(join)
        ctx.setLineCap(.round)
        switch el.raw["strokeStyle"] as? String {
        case "dashed": ctx.setLineDash(phase: 0, lengths: [8, 8 + width]); ctx.setLineCap(.butt)
        case "dotted": ctx.setLineDash(phase: 0, lengths: [1.5, 6 + width])
        default: ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.strokePath()
    }

    // MARK: 手寫

    /// 寬度隨點變化：相鄰兩點畫一段圓頭線段，寬度取兩點平均
    private func drawFreedraw(_ el: Element, in ctx: CGContext) {
        let pts = el.absolutePoints
        guard let strokeColor = color(el, "strokeColor"), let first = pts.first else { return }
        let widths = ElementGeometry.freedrawWidths(el)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: [])
        guard pts.count > 1 else {
            let d = widths.first ?? 2
            ctx.setFillColor(strokeColor)
            ctx.fillEllipse(in: CGRect(x: first.x - d / 2, y: first.y - d / 2, width: d, height: d))
            return
        }
        // 寬度幾乎不變時合併成一條路徑，接縫比較平順
        let minW = widths.min() ?? 1, maxW = widths.max() ?? 1
        if maxW - minW < 0.25 {
            ctx.setLineWidth(maxW)
            ctx.addLines(between: pts)
            ctx.strokePath()
            return
        }
        for i in 1..<pts.count {
            ctx.setLineWidth(((widths[safe: i - 1] ?? minW) + (widths[safe: i] ?? minW)) / 2)
            ctx.move(to: pts[i - 1])
            ctx.addLine(to: pts[i])
            ctx.strokePath()
        }
    }

    // MARK: 文字

    /// `text` 已是換行後的結果（Excalidraw 存檔時就換好行），逐行依 `textAlign` 對齊
    private func drawText(_ el: Element, in ctx: CGContext) {
        guard let textColor = color(el, "strokeColor") else { return }
        drawLines(el.text.components(separatedBy: "\n"), in: el.rect.standardized, fontSize: el.fontSize,
                  lineHeight: el.lineHeight, align: el.textAlign, color: textColor, ctx: ctx)
    }

    private func drawLines(_ lines: [String], in rect: CGRect, fontSize: Double, lineHeight: Double, align: String,
                           color: CGColor, ctx: CGContext) {
        let font = TextLayout.font(size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ]
        let lineBox = fontSize * lineHeight
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (i, text) in lines.enumerated() where !text.isEmpty {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
            let x: Double = switch align {
            case "center": rect.minX + (rect.width - width) / 2
            case "right": rect.maxX - width
            default: rect.minX
            }
            // 字形在行高中垂直置中
            let baseline = rect.minY + Double(i) * lineBox + lineBox / 2 + (ascent - descent) / 2
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    // MARK: 圖片

    private func drawImage(_ el: Element, in ctx: CGContext, pixelScale: CGFloat) {
        let rect = el.rect.standardized
        let scale = (el.raw["scale"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [1, 1]
        let needed = Int((max(rect.width, rect.height) * pixelScale).rounded(.up))
        guard let fileId = el.fileId, var image = decodedImage(fileId, maxPixels: needed) else {
            drawPlaceholder(el, title: "圖片", in: ctx)
            return
        }
        // crop：原圖像素座標的裁切範圍
        if let crop = el.raw["crop"] as? [String: Any],
           let cx = num(crop["x"]), let cy = num(crop["y"]), let cw = num(crop["width"]), let ch = num(crop["height"]),
           let nw = num(crop["naturalWidth"]), nw > 0 {
            let k = Double(image.width) / nw
            if let cropped = image.cropping(to: CGRect(x: cx * k, y: cy * k, width: cw * k, height: ch * k).integral) {
                image = cropped
            }
        }
        ctx.saveGState()
        if el.raw["roundness"] is [String: Any] {
            ctx.addPath(ElementGeometry.outline(el))
            ctx.clip()
        }
        // `scale` 為 -1 = 翻轉；CGContext 畫圖時原點在左下，所以垂直方向再翻一次
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: scale.first.map { $0 < 0 ? -1 : 1 } ?? 1, y: -(scale[safe: 1].map { $0 < 0 ? -1 : 1 } ?? 1))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// 依顯示大小解碼縮圖，不解碼原圖。像素大小取 2 的冪次，相近的大小共用快取
    private func decodedImage(_ fileId: String, maxPixels: Int) -> CGImage? {
        var bucket = 64
        while bucket < maxPixels && bucket < 4096 { bucket *= 2 }
        let key = "\(fileId)@\(bucket)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let file = files[fileId] as? [String: Any], let url = file["dataURL"] as? String,
              let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    // MARK: frame 與佔位框

    private func drawFrame(_ el: Element, in ctx: CGContext) {
        let path = ElementGeometry.outline(el)
        if let fill = color(el, "backgroundColor") {
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        // 與 Excalidraw 相同：frame 的外框與標題用固定樣式，不看 strokeColor
        ctx.addPath(path)
        ctx.setStrokeColor(SceneColor.frameStroke)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.strokePath()
        let name = (el.raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Frame"
        // 標題在 frame 外，不受子元素的裁切影響（frame 本身沒有 frameId）
        drawLines([name], in: ElementGeometry.frameTitleRect(el), fontSize: ElementGeometry.frameTitleSize,
                  lineHeight: 1.25, align: "left", color: SceneColor.frameTitle, ctx: ctx)
    }

    /// 不支援顯示的元素（embeddable、iframe、未知類型）、找不到資料的圖片：帶標題的虛線框
    private func drawPlaceholder(_ el: Element, title: String, in ctx: CGContext) {
        let rect = el.rect.standardized
        let path = CGPath(roundedRect: rect, cornerWidth: min(8, rect.width / 2), cornerHeight: min(8, rect.height / 2),
                          transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(SceneColor.placeholderFill)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(SceneColor.placeholderStroke)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.strokePath()
        let size = min(14, max(rect.height / 3, 6))
        let titleRect = CGRect(x: rect.minX + 4, y: rect.midY - size * 1.25 / 2, width: max(rect.width - 8, 1), height: size * 1.25)
        drawLines([title], in: titleRect, fontSize: size, lineHeight: 1.25, align: "center",
                  color: SceneColor.placeholderStroke, ctx: ctx)
    }

    private func placeholderTitle(_ el: Element, type: String) -> String {
        if let name = el.raw["name"] as? String, !name.isEmpty { return name }
        if let link = el.link, !link.isEmpty {
            return URL(string: link)?.host() ?? link
        }
        return type
    }

    // MARK: 工具

    private func color(_ el: Element, _ key: String) -> CGColor? {
        SceneColor.parse(el.raw[key] as? String ?? (key == "strokeColor" ? "#1e1e1e" : "transparent"))
    }

    private func num(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// Excalidraw 的顏色字串（`#rgb`、`#rrggbb`、`#rrggbbaa`、`transparent`、少數 CSS 名稱）
enum SceneColor {
    static let frameStroke = rgb(0xbbbbbb)
    static let frameTitle = rgb(0x999999)
    static let placeholderFill = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.08)
    static let placeholderStroke = rgb(0x868e96)

    static func isWhite(_ color: CGColor) -> Bool {
        (color.components ?? []).allSatisfy { $0 > 0.99 }
    }

    /// 透明或無法解析回傳 nil（不畫）
    static func parse(_ string: String) -> CGColor? {
        let s = string.trimmingCharacters(in: .whitespaces).lowercased()
        switch s {
        case "", "transparent", "none": return nil
        case "black": return rgb(0x000000)
        case "white": return rgb(0xffffff)
        default: break
        }
        guard s.hasPrefix("#") else { return nil }
        var hex = String(s.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 { return rgb(Int(value)) }
        let alpha = Double(value & 0xff) / 255
        guard alpha > 0 else { return nil }
        return rgb(Int(value >> 8), alpha: alpha)
    }

    static func rgb(_ v: Int, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                blue: Double(v & 0xff) / 255, alpha: alpha)
    }
}
