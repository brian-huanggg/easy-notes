import CoreGraphics
import CoreText
import Foundation

/// 文字排版（CoreText）。模型的換行、尺寸與之後 4b 的渲染共用這一份，所以兩邊看到的換行一致。
/// 字型一律用系統字型（拉丁字 SF、中文蘋方），不模擬 Excalidraw 的 `fontFamily`。
public enum TextLayout {
    public struct Result: Equatable {
        public var lines: [String]
        public var size: CGSize
    }

    /// Excalidraw 的 BOUND_TEXT_PADDING
    public static let boundPadding: Double = 5

    /// 換行與量測。`maxWidth` 為 nil 時只依 `\n` 斷行；CJK 可在任何字之間斷行。
    public static func layout(_ text: String, fontSize: Double, lineHeight: Double, maxWidth: Double?) -> Result {
        let font = Self.font(size: fontSize)
        var lines: [String] = []
        var width: Double = 0

        for paragraph in text.components(separatedBy: "\n") {
            if paragraph.isEmpty { lines.append(""); continue }
            let attributed = NSAttributedString(string: paragraph, attributes: [.init(kCTFontAttributeName as String): font])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let ns = paragraph as NSString
            var start = 0
            while start < ns.length {
                let count = maxWidth.map { CTTypesetterSuggestLineBreak(typesetter, start, max($0, 1)) }
                    ?? (ns.length - start)
                let range = CFRange(location: start, length: max(count, 1))
                let line = CTTypesetterCreateLine(typesetter, range)
                let trailing = CTLineGetTrailingWhitespaceWidth(line)
                width = max(width, CTLineGetTypographicBounds(line, nil, nil, nil) - trailing)
                let piece = ns.substring(with: NSRange(location: range.location, length: range.length))
                lines.append(piece.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
                start += range.length
            }
        }
        if lines.isEmpty { lines = [""] }
        return Result(lines: lines, size: CGSize(width: width.rounded(.up), height: Double(lines.count) * fontSize * lineHeight))
    }

    /// 系統字型；中文由 CoreText 的字型遞補換成蘋方
    public static func font(size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
    }

    /// 依 `originalText` 重新排版並設定 `text`、`width`、`height`。`maxWidth` 為 nil = 不自動換行（獨立文字）。
    static func fit(_ el: inout Element, maxWidth: Double?) {
        let source = el.raw["originalText"] as? String ?? el.text
        let result = layout(source, fontSize: el.fontSize, lineHeight: el.lineHeight, maxWidth: maxWidth)
        el.raw["text"] = result.lines.joined(separator: "\n")
        el.raw["originalText"] = source
        el.width = result.size.width
        el.height = result.size.height
    }

    // MARK: 容器內文字

    /// 容器內可放文字的最大寬度（橢圓、菱形取內接矩形，與 Excalidraw 相同）
    static func maxWidth(in container: Element) -> Double {
        let inner: Double
        switch container.type {
        case .ellipse: inner = (container.width / 2 * 2.0.squareRoot()).rounded()
        case .diamond: inner = (container.width / 2).rounded()
        default: inner = container.width
        }
        return max(inner - boundPadding * 2, 1)
    }

    /// 容器要容納 `textHeight` 所需的高度
    static func containerHeight(fitting textHeight: Double, in container: Element) -> Double {
        let padded = textHeight + boundPadding * 2
        switch container.type {
        case .ellipse: return (padded * 2.0.squareRoot()).rounded(.up)
        case .diamond: return padded * 2
        default: return padded
        }
    }
}
