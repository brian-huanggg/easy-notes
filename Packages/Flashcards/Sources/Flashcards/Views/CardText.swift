import EasyNotesUI
@preconcurrency import SwiftMath
import SwiftUI

/// 卡片文字（見 architecture/flashcards.md「卡片內容」）：行內 Markdown 與公式，獨立公式自成一段、置中。
/// 文字顏色跟著外層的 `foregroundStyle`；克漏字的挖空處與答案用 `highlight`
struct CardText: View {
    let segments: [StudyCard.Segment]
    let style: TextStyle
    let highlight: ColorToken

    var body: some View {
        VStack(alignment: .leading, spacing: style.size * 0.4) {
            ForEach(Array(CardMarkup.blocks(segments).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let inlines):
                    Self.text(inlines, size: style.size, highlight: highlight).textStyle(style)
                case .math(let latex, let mathStyle):
                    DisplayMath(latex: latex, size: style.size, highlight: mathStyle.contains(.cloze) ? highlight : nil)
                }
            }
        }
    }

    /// 單一個 `Text`（列表等需要 `lineLimit` 的地方）：獨立公式也排在行內
    static func text(_ segments: [StudyCard.Segment], size: CGFloat, highlight: ColorToken) -> Text {
        let inlines = CardMarkup.blocks(segments).flatMap { block -> [CardMarkup.Inline] in
            switch block {
            case .paragraph(let inlines): inlines
            case .math(let latex, let style): [.text(" "), .math(latex, style), .text(" ")]
            }
        }
        return text(inlines, size: size, highlight: highlight)
    }

    static func text(_ inlines: [CardMarkup.Inline], size: CGFloat, highlight: ColorToken) -> Text {
        inlines.reduce(Text("")) { result, inline in
            switch inline {
            case .text(let string, let style, let link):
                return result + Text(attributed(string, style, link: link, highlight: highlight))
            case .math(let latex, let style):
                return result + MathImage.text(latex, size: size, color: style.contains(.cloze) ? highlight : nil)
            }
        }
    }

    private static func attributed(_ string: String, _ style: CardMarkup.Style, link: String?,
                                   highlight: ColorToken) -> AttributedString {
        var result = AttributedString(string)
        var intent: InlinePresentationIntent = []
        if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
        if style.contains(.italic) { intent.insert(.emphasized) }
        if style.contains(.strike) { intent.insert(.strikethrough) }
        if style.contains(.code) { intent.insert(.code) }
        if !intent.isEmpty { result.inlinePresentationIntent = intent }
        if style.contains(.highlight) { result.backgroundColor = Palette.warnSoft.color }
        if style.contains(.code) { result.backgroundColor = Palette.bgHover.color }
        if let link, let url = URL(string: link) {
            result.link = url
            result.foregroundColor = Palette.accent.color
        }
        if style.contains(.cloze) { result.foregroundColor = highlight.color }
        return result
    }
}

/// `$$…$$`：置中；比可用寬度寬時等比縮小
private struct DisplayMath: View {
    let latex: String
    let size: CGFloat
    let highlight: ColorToken?

    var body: some View {
        Group {
            if let highlight {
                formula.foregroundStyle(highlight)
            } else {
                formula
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var formula: some View {
        if let rendered = MathImage.render(latex, size: size, display: true) {
            Image(platformImage: rendered.image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: rendered.size.width, maxHeight: rendered.size.height)
        } else {
            MathImage.fallback(latex, display: true)
        }
    }
}

/// SwiftMath 排版的公式圖片（template，顏色跟著前景色），依 LaTeX、字級快取
@MainActor
enum MathImage {
    struct Rendered {
        let image: PlatformImage
        let size: CGSize
        /// 公式基線到圖片底部的距離；`Text` 中的圖片以底部對齊文字基線，所以要往下移這麼多
        let baseline: CGFloat
    }

    private struct Key: Hashable {
        let latex: String
        let size: CGFloat
        let display: Bool
    }

    /// nil = 無法解析（也快取，避免每次重畫都再試一次）
    private static var cache: [Key: Rendered?] = [:]

    static func render(_ latex: String, size: CGFloat, display: Bool) -> Rendered? {
        let key = Key(latex: latex, size: size, display: display)
        if let cached = cache[key] { return cached }
        if cache.count > 500 { cache.removeAll() }
        let rendered = draw(latex, size: size, display: display)
        cache[key] = rendered
        return rendered
    }

    private static func draw(_ latex: String, size: CGFloat, display: Bool) -> Rendered? {
        let mode: MTMathUILabelMode = display ? .display : .text
        let (error, image) = MTMathImage(latex: latex, fontSize: size, textColor: .black, labelMode: mode,
                                         textAlignment: .left).asImage()
        guard error == nil, let image else { return nil }

        // MTMathImage 不提供 descent，用同一組設定的 label 排版一次取得
        let label = MTMathUILabel()
        label.fontSize = size
        label.labelMode = mode
        label.latex = latex
        label.frame = CGRect(origin: .zero, size: image.size)
        #if os(macOS)
        label.layout()
        #else
        label.layoutSubviews()
        #endif
        guard let list = label.displayList else { return nil }
        // 與 MTMathImage 相同的垂直置中：高度不足半個字級時以半個字級置中
        let height = list.ascent + list.descent
        let baseline = (height - max(height, size / 2)) / 2 + list.descent
        return Rendered(image: image, size: image.size, baseline: baseline)
    }

    static func text(_ latex: String, size: CGFloat, color: ColorToken?) -> Text {
        guard let rendered = render(latex, size: size, display: false) else { return fallback(latex, display: false) }
        let text = Text(Image(platformImage: rendered.image).renderingMode(.template)).baselineOffset(-rendered.baseline)
        return color.map { text.foregroundColor($0.color) } ?? text
    }

    /// 無法解析的公式：以程式碼樣式顯示原文
    static func fallback(_ latex: String, display: Bool) -> Text {
        let delimiter = display ? "$$" : "$" // l10n:fixed LaTeX 分隔符
        var source = AttributedString(delimiter + latex + delimiter)
        source.inlinePresentationIntent = .code
        source.foregroundColor = Palette.textSecondary.color
        return Text(source)
    }
}

#if os(macOS)
typealias PlatformImage = NSImage

private extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
typealias PlatformImage = UIImage

private extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif
