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
    let painter: ElementPainter
    private let byID: [String: Element]
    private let boundsCache: [CGRect]

    /// `transparentDefaultBackground`：白色（預設）背景改為透明，讓縮圖與嵌入融入卡片底色、深色模式可以反相；
    /// 使用者自訂的背景色仍然畫出來
    public init(scene: ExcalidrawScene, transparentDefaultBackground: Bool = false) {
        elements = scene.liveElements
        painter = ElementPainter(files: scene.raw["files"] as? [String: Any] ?? [:])
        byID = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        boundsCache = elements.map(ElementGeometry.bounds)
        let bg = (scene.raw["appState"] as? [String: Any])?["viewBackgroundColor"] as? String
        let color = SceneColor.parse(bg ?? "#ffffff")
        background = transparentDefaultBackground && color.map(SceneColor.isWhite) ?? true ? nil : color
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
    public func draw(in ctx: CGContext, visible: CGRect? = nil, pixelScale: CGFloat = 1, drawsFreedraw: Bool = true) {
        for (i, el) in elements.enumerated() {
            if !drawsFreedraw, el.type == .freedraw { continue }
            if let visible, !boundsCache[i].intersects(visible) { continue }
            // frame 內的元素依 frame 範圍裁切
            let frame = el.frameId.flatMap { byID[$0] }.flatMap { $0.type == .frame ? $0 : nil }
            ctx.saveGState()
            if let frame { ctx.clip(to: frame.rect.standardized) }
            painter.draw(el, in: ctx, pixelScale: pixelScale)
            ctx.restoreGState()
        }
    }
}

/// Excalidraw 的顏色字串（`#rgb`、`#rrggbb`、`#rrggbbaa`、`transparent`、少數 CSS 名稱）
public enum SceneColor {
    public static let frameStroke = rgb(0xbbbbbb)
    static let frameTitle = rgb(0x999999)
    static let placeholderFill = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.08)
    static let placeholderStroke = rgb(0x868e96)

    static func isWhite(_ color: CGColor) -> Bool {
        (color.components ?? []).allSatisfy { $0 > 0.99 }
    }

    /// 透明或無法解析回傳 nil（不畫）
    public static func parse(_ string: String) -> CGColor? {
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

    public static func rgb(_ v: Int, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                blue: Double(v & 0xff) / 255, alpha: alpha)
    }
}
