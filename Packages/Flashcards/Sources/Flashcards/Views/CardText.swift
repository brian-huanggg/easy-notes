import AVFoundation
import EasyNotesUI
@preconcurrency import SwiftMath
import SwiftUI

/// 卡片文字（見 architecture/flashcards.md「卡片內容」）：行內 Markdown 與公式，獨立公式自成一段、置中。
/// 文字顏色跟著外層的 `foregroundStyle`；克漏字的挖空處與答案用 `highlight`
struct CardText: View {
    let segments: [StudyCard.Segment]
    let style: TextStyle
    let highlight: ColorToken
    /// 排版寬度；行內公式比它寬時縮小，避免超出卡片（0 = 還不知道）
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: style.size * 0.4) {
            ForEach(Array(CardMarkup.blocks(segments).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let inlines):
                    Self.text(inlines, size: style.size, highlight: highlight, maxWidth: width)
                        .textStyle(style)
                        .fixedSize(horizontal: false, vertical: true)
                case .math(let latex, let mathStyle):
                    DisplayMath(latex: latex, size: style.size, highlight: mathStyle.contains(.cloze) ? highlight : nil)
                case .listItem(let level, let marker, let inlines):
                    HStack(alignment: .firstTextBaseline, spacing: style.size * 0.4) {
                        Text(marker ?? "").textStyle(style).foregroundStyle(Palette.textTertiary)
                            .frame(minWidth: style.size * 0.6, alignment: .trailing)
                        Self.text(inlines, size: style.size, highlight: highlight,
                                  maxWidth: width - CGFloat(level + 1) * style.size * 1.2)
                            .textStyle(style)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(level) * style.size * 1.2)
                case .code(let code):
                    Text(code)
                        .font(.system(size: style.size * 0.8, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.bgHover))
                case .image(let path, let width):
                    CardImage(path: path, width: width)
                case .audio(let path):
                    CardAudio(path: path)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// 單一個 `Text`（列表等需要 `lineLimit` 的地方）：獨立公式也排在行內，區塊之間換行，圖片顯示為檔名
    static func text(_ segments: [StudyCard.Segment], size: CGFloat, highlight: ColorToken) -> Text {
        let inlines = CardMarkup.blocks(segments).enumerated().flatMap { index, block -> [CardMarkup.Inline] in
            let lead: [CardMarkup.Inline] = index == 0 ? [] : [.text("\n")]
            switch block {
            case .paragraph(let inlines): return lead + inlines
            case .math(let latex, let style): return lead + [.math(latex, style)]
            case .listItem(_, let marker, let inlines): return lead + [.text((marker ?? " ") + " ")] + inlines
            case .code(let code): return lead + [.text(code, .code)]
            case .audio(let path): return lead + [.text("[" + (path as NSString).lastPathComponent + "]")] // l10n:fixed
            case .image(let path, _): return lead + [.text("[" + (path as NSString).lastPathComponent + "]")] // l10n:fixed
            }
        }
        return text(inlines, size: size, highlight: highlight)
    }

    static func text(_ inlines: [CardMarkup.Inline], size: CGFloat, highlight: ColorToken,
                     maxWidth: CGFloat = 0) -> Text {
        inlines.reduce(Text("")) { result, inline in
            switch inline {
            case .text(let string, let style, let link):
                return result + Text(attributed(string, style, link: link, highlight: highlight))
            case .math(let latex, let style):
                return result + MathImage.text(latex, size: size, color: style.contains(.cloze) ? highlight : nil, maxWidth: maxWidth)
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

/// `![[x.png]]`：寬度不超過卡片（有指定寬度時照指定，不放大），高度上限 400pt；讀不到時顯示原文
private struct CardImage: View {
    let path: String
    let width: Double?
    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var previewing = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(width.map { CGFloat($0) } ?? .infinity, image.size.width), maxHeight: 400)
                    .contentShape(Rectangle())
                    .onTapGesture { previewing = true }
                    .help(L("點一下放大"))
                    .sheet(isPresented: $previewing) { ImagePreview(image: image) }
            } else if failed {
                Text("![[" + (path as NSString).lastPathComponent + "]]") // l10n:fixed 嵌入語法
                    .textStyle(.meta)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Color.clear.frame(height: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: path) {
            image = await ReviewStore.shared.cardImage(path)
            failed = image == nil
        }
    }
}

/// 圖片放大檢視：預設縮放到視窗大小（小圖會放大），點一下切換原始大小（可捲動）
private struct ImagePreview: View {
    let image: PlatformImage
    @Environment(\.dismiss) private var dismiss
    @State private var actualSize = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if actualSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(platformImage: image)
                            .resizable()
                            .frame(width: image.size.width, height: image.size.height)
                    }
                } else {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { actualSize.toggle() }
            IconButton("xmark", help: L("關閉")) { dismiss() }.padding(14)
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 680)
        #endif
        .background(Palette.bgCanvas)
    }
}

/// `![[x.mp3]]`：播放鈕加檔名；讀不到時顯示原文
private struct CardAudio: View {
    let path: String
    @State private var player = CardAudioPlayer()
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Text("![[" + (path as NSString).lastPathComponent + "]]") // l10n:fixed 嵌入語法
                    .textStyle(.meta)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Button {
                    Task {
                        if player.isPlaying {
                            player.stop()
                        } else if let data = await ReviewStore.shared.cardResource(path) {
                            failed = !player.play(data)
                        } else {
                            failed = true
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: player.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 24))
                        Text((path as NSString).lastPathComponent).textStyle(.meta)
                    }
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { player.stop() }
    }
}

/// 一次播放一個音檔；播完或換卡時停止
@MainActor @Observable
final class CardAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?

    func play(_ data: Data) -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.delegate = self
        self.player = player
        isPlaying = player.play()
        return isPlaying
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
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

    /// `maxWidth` > 0 且公式比它寬時，縮小字級讓公式排進一行（最小縮到 40%）
    static func text(_ latex: String, size: CGFloat, color: ColorToken?, maxWidth: CGFloat = 0) -> Text {
        guard var rendered = render(latex, size: size, display: false) else { return fallback(latex, display: false) }
        if maxWidth > 0, rendered.size.width > maxWidth {
            let scaled = max(size * 0.4, size * maxWidth / rendered.size.width)
            // 視窗縮放時寬度連續變動，字級以 0.5pt 為單位才不會塞滿快取
            let fitted = (scaled * 2).rounded(.down) / 2
            if let smaller = render(latex, size: fitted, display: false) { rendered = smaller }
        }
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

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif
