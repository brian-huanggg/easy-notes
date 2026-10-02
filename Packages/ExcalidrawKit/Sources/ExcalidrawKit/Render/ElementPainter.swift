import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// 畫單一元素（CoreGraphics，畫布座標、y 向下）。`SceneRenderer` 依序畫整個場景；
/// 編輯器的 layer 樹用它畫文字、圖片、手寫與佔位框這些不是純路徑的元素，所以兩邊看起來一致。
public final class ElementPainter: @unchecked Sendable {
    private let files: [String: Any]
    /// 解碼過的圖片（依 fileId 與像素大小）；重畫時不必重新解碼
    private let imageCache = NSCache<NSString, CGImage>()

    public init(files: [String: Any]) {
        self.files = files
        imageCache.countLimit = 64
    }

    /// 畫一個元素，含 `angle` 旋轉與透明度
    func draw(_ el: Element, in ctx: CGContext, pixelScale: CGFloat) {
        let opacity = ((el.raw["opacity"] as? NSNumber)?.doubleValue ?? 100) / 100
        guard opacity > 0 else { return }
        ctx.concatenate(ElementGeometry.rotation(el))
        // 半透明：整個元素合成後才套用透明度，重疊的部分（手寫線段、箭頭頭部）不會變深
        let layered = opacity < 1
        if layered {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        drawContent(el, in: ctx, pixelScale: pixelScale)
        if layered { ctx.endTransparencyLayer() }
    }

    /// 畫元素本身，不含旋轉與透明度（layer 樹由 layer 的 transform 與 opacity 處理）
    public func drawContent(_ el: Element, in ctx: CGContext, pixelScale: CGFloat) {
        switch el.type {
        case .rectangle, .diamond, .ellipse: drawShape(el, in: ctx)
        case .line, .arrow: drawLinear(el, in: ctx)
        case .freedraw: drawFreedraw(el, in: ctx)
        case .text: drawText(el, in: ctx)
        case .image: drawImage(el, in: ctx, pixelScale: pixelScale)
        case .frame: drawFrame(el, in: ctx)
        case .unknown(let type): drawPlaceholder(el, title: placeholderTitle(el, type: type), in: ctx)
        }
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
        drawFrameTitle(el, in: ctx)
    }

    /// 標題在 frame 外，不受子元素的裁切影響（frame 本身沒有 frameId）
    public func drawFrameTitle(_ el: Element, in ctx: CGContext) {
        let name = (el.raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Frame"
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
