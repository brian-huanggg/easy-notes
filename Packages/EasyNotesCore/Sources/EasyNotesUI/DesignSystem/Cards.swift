import SwiftUI

/// The frame of a card thumbnail: corner radius, border, background. Content comes from plugin previews (Markdown title + first lines, whiteboard, PDF first page…)
public struct PreviewFrame<Content: View>: View {
    let height: CGFloat
    let fill: ColorToken
    /// Mouse over: the border darkens and the card lifts
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

/// Placeholder when there is no real preview: a title bar + several gray text lines (the design's Doc Card Preview Lines)
public struct SkeletonPreview: View {
    let lines: [CGFloat]
    let scale: CGFloat

    /// `lines`: relative width of each line (0…1). `scale`: 1 for Desktop cards, about 0.7 for Mobile Pin Cards
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

/// A translucent badge at the lower left of a card ("Pinned")
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

/// Design `C/Doc Card` (Desktop grid) and `C/M Pin Card` (Mobile pinned row): thumbnail + type icon + title + one-line summary
public struct DocCard<Preview: View>: View {
    public enum Size: Sendable {
        /// Desktop: thumbnail height 154
        case regular
        /// Mobile pinned: width 158, thumbnail height 102
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

/// Type tile: soft background + border + an icon in the type color (Mobile Doc Row, link card)
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

/// Design `C/M Doc Row`: type tile + title + summary + chevron. Also used for link cards inside the editor (`style: .card`)
public struct DocRow: View {
    public enum Style: Sendable {
        /// Mobile list: tile 44, title 15
        case list
        /// `[[link]]` card: panel background, border, tile 32
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
        // The list style has no horizontal padding: the hover background extends outward
        .hoverBackground(cornerRadius: Metrics.radiusMedium, outset: 8, isActive: !card)
        .contentShape(Rectangle())
        .modifier(Hovering(isHovering: $hovering))
        .clickablePointer()
        .accessibilityElement(children: .combine)
    }
}
