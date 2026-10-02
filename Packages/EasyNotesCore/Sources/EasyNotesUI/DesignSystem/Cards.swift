import SwiftUI

/// 卡片縮圖的外框：圓角、邊框、底色。內容由外掛的預覽提供（Markdown 標題 + 前幾行、白板、PDF 首頁…）
public struct PreviewFrame<Content: View>: View {
    let height: CGFloat
    let fill: ColorToken
    /// 滑鼠移過：邊框加深並浮起
    let isHighlighted: Bool
    let content: Content

    public init(height: CGFloat, fill: ColorToken = Palette.bgCanvas, isHighlighted: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.height = height
        self.fill = fill
        self.isHighlighted = isHighlighted
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
        content
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(fill)
            .clipShape(shape)
            .overlay(shape.strokeBorder(isHighlighted ? Palette.borderStrong : Palette.border))
            .shadow(color: .black.opacity(isHighlighted ? 0.08 : 0), radius: 8, y: 3)
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }
}

/// 沒有真實預覽時的佔位：一條標題 + 幾條灰色文字行（設計稿 Doc Card 的 Preview Lines）
public struct SkeletonPreview: View {
    let lines: [CGFloat]
    let scale: CGFloat

    /// `lines`：每行相對寬度（0…1）。`scale`：Desktop 卡片 1、Mobile Pin Card 約 0.7
    public init(lines: [CGFloat] = [0.84, 0.78, 0.72, 0.81, 0.58], scale: CGFloat = 1) {
        self.lines = lines
        self.scale = scale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7 * scale) {
            Capsule().fill(Palette.borderStrong).frame(width: 112 * scale, height: 9 * scale)
                .padding(.bottom, 1)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, width in
                GeometryReader { proxy in
                    Capsule().fill(Palette.skeleton).frame(width: proxy.size.width * width)
                }
                .frame(height: 5 * scale)
            }
        }
        .padding(15 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// 卡片左下角的半透明標記（「Pinned」）
public struct PreviewBadge: View {
    let title: String
    let symbol: String?

    public init(_ title: String, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9)) }
            Text(title).textStyle(TextStyle(10.5, .semibold))
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.surfaceGlass))
    }
}

/// 設計稿 `C/Doc Card`（Desktop 網格）與 `C/M Pin Card`（Mobile 釘選列）：縮圖 + 類型圖示 + 標題 + 一行摘要
public struct DocCard<Preview: View>: View {
    public enum Size: Sendable {
        /// Desktop：縮圖高 154
        case regular
        /// Mobile 釘選：寬 158、縮圖高 102
        case compact
    }

    let title: String
    let symbol: String
    let tint: KindTint
    let meta: String
    let badge: PreviewBadge?
    let size: Size
    let preview: Preview
    @State private var hovering = false

    public init(_ title: String, symbol: String, tint: KindTint, meta: String, badge: PreviewBadge? = nil,
                size: Size = .regular, @ViewBuilder preview: () -> Preview) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.meta = meta
        self.badge = badge
        self.size = size
        self.preview = preview()
    }

    public var body: some View {
        let compact = size == .compact
        VStack(alignment: .leading, spacing: compact ? 10 : 11) {
            PreviewFrame(height: compact ? 102 : 154, isHighlighted: hovering) { preview }
                .overlay(alignment: .bottomLeading) {
                    badge?.padding(10)
                }
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(spacing: compact ? 5 : 6) {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(tint.base)
                    Text(title)
                        .textStyle(.cardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                }
                Text(meta)
                    .textStyle(.meta)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? 0 : 2)
        }
        .frame(width: compact ? 158 : nil)
        .contentShape(Rectangle())
        .modifier(Hovering(isHovering: $hovering))
        .clickablePointer()
        .accessibilityElement(children: .combine)
    }
}

public extension DocCard where Preview == SkeletonPreview {
    init(_ title: String, symbol: String, tint: KindTint, meta: String, badge: PreviewBadge? = nil,
         size: Size = .regular) {
        self.init(title, symbol: symbol, tint: tint, meta: meta, badge: badge, size: size) {
            SkeletonPreview(scale: size == .compact ? 0.7 : 1)
        }
    }
}

/// 類型圖塊：soft 底 + 邊框 + 類型顏色的圖示（Mobile Doc Row、連結卡片）
public struct KindTile: View {
    let symbol: String
    let tint: KindTint
    let size: CGFloat

    public init(symbol: String, tint: KindTint, size: CGFloat = 44) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size >= 40 ? Metrics.radiusMedium : 9, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.42))
            .foregroundStyle(tint.base)
            .frame(width: size, height: size)
            .background(shape.fill(tint.soft))
            .overlay(shape.strokeBorder(Palette.border))
    }
}

/// 設計稿 `C/M Doc Row`：類型圖塊 + 標題 + 摘要 + chevron。也用於編輯器內的連結卡片（`style: .card`）
public struct DocRow: View {
    public enum Style: Sendable {
        /// Mobile 列表：圖塊 44、標題 15
        case list
        /// `[[連結]]` 卡片：panel 底、邊框、圖塊 32
        case card
    }

    let title: String
    let symbol: String
    let tint: KindTint
    let meta: String
    let style: Style
    @State private var hovering = false

    public init(_ title: String, symbol: String, tint: KindTint, meta: String, style: Style = .list) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.meta = meta
        self.style = style
    }

    public var body: some View {
        let card = style == .card
        HStack(spacing: card ? 11 : 13) {
            KindTile(symbol: symbol, tint: tint, size: card ? 32 : 44)
            VStack(alignment: .leading, spacing: card ? 2 : 3) {
                Text(title)
                    .textStyle(card ? TextStyle(13.5, .semibold) : .rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(meta)
                    .textStyle(card ? .meta : .rowMeta)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: card ? 12 : 13, weight: .medium))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.vertical, card ? 12 : 8)
        .padding(.horizontal, card ? 13 : 0)
        .background {
            if card {
                RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
                    .fill(hovering ? Palette.bgHover : Palette.bgPanel)
                RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
                    .strokeBorder(hovering ? Palette.borderStrong : Palette.border)
            }
        }
        // 列表樣式沒有左右內距：hover 底色往外延伸
        .hoverBackground(cornerRadius: Metrics.radiusMedium, outset: 8, isActive: !card)
        .contentShape(Rectangle())
        .modifier(Hovering(isHovering: $hovering))
        .clickablePointer()
        .accessibilityElement(children: .combine)
    }
}
