import SwiftUI

// MARK: - Hover

private struct HoverBackground: ViewModifier {
    let cornerRadius: CGFloat
    let outset: CGFloat
    let isActive: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: -outset)
                    .fill(Palette.bgHover)
                    .opacity(hovering && isActive ? 1 : 0)
            )
            #if os(macOS)
            .onHover { hovering = $0 }
            #endif
    }
}

/// 可點擊的列表項目：macOS 滑鼠移過時游標變成手指；iPad 指標移過時有系統的 highlight
private struct ClickablePointer: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.pointerStyle(.link)
        #else
        content.hoverEffect(.highlight)
        #endif
    }
}

public extension View {
    /// macOS 滑鼠移過時顯示 `bg-hover`；iOS 不做事。`outset`：hover 底色超出內容的距離（內容本身沒有內距時）
    func hoverBackground(cornerRadius: CGFloat = Metrics.radiusSmall, outset: CGFloat = 0, isActive: Bool = true) -> some View {
        modifier(HoverBackground(cornerRadius: cornerRadius, outset: outset, isActive: isActive))
    }

    /// 文件、資料夾等可點擊項目的游標
    func clickablePointer() -> some View {
        modifier(ClickablePointer())
    }
}

/// 滑鼠是否在 view 上（只有 macOS 會變成 true）
struct Hovering: ViewModifier {
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onHover { isHovering = $0 }
        #else
        content
        #endif
    }
}

// MARK: - 按鈕

/// 主要按鈕：accent 底、白字（New Document、空狀態的 New Note）
public struct PrimaryButtonStyle: ButtonStyle {
    public enum Size: Sendable { case regular, large }
    let size: Size
    /// 停用時改成灰底灰字（`.disabled(_:)` 不會自動改變自訂樣式的外觀）
    @Environment(\.isEnabled) private var isEnabled

    public init(size: Size = .regular) { self.size = size }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.button)
            .labelStyle(CompactLabelStyle(spacing: 6))
            .foregroundStyle(isEnabled ? Color.white : Palette.textTertiary.color)
            .padding(.vertical, size == .large ? 8 : 6)
            .padding(.horizontal, size == .large ? 14 : 12)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).fill(isEnabled ? Palette.accent : Palette.bgHover))
            .shadow(color: isEnabled ? Palette.accent.color.opacity(0.25) : .clear, radius: 2, y: 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// 次要按鈕：surface-raised 底、邊框（New Whiteboard、排序）
public struct SecondaryButtonStyle: ButtonStyle {
    let size: PrimaryButtonStyle.Size

    public init(size: PrimaryButtonStyle.Size = .regular) { self.size = size }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
        configuration.label
            .textStyle(size == .large ? .button : .control)
            .labelStyle(CompactLabelStyle(spacing: 6))
            .foregroundStyle(size == .large ? Palette.textPrimary : Palette.textSecondary)
            .padding(.vertical, size == .large ? 8 : 5)
            .padding(.horizontal, size == .large ? 14 : 9)
            .background(shape.fill(configuration.isPressed ? Palette.bgHover : Palette.surfaceRaised))
            .overlay(shape.strokeBorder(Palette.border))
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var enPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func enPrimary(size: PrimaryButtonStyle.Size) -> PrimaryButtonStyle { PrimaryButtonStyle(size: size) }
}

public extension ButtonStyle where Self == SecondaryButtonStyle {
    static var enSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func enSecondary(size: PrimaryButtonStyle.Size) -> SecondaryButtonStyle { SecondaryButtonStyle(size: size) }
}

/// 圖示與文字間距較緊的 Label
public struct CompactLabelStyle: LabelStyle {
    let spacing: CGFloat
    public init(spacing: CGFloat = 6) { self.spacing = spacing }
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// 設計稿 `C/Icon Button`：28×28、16pt 圖示，滑鼠移過時有底色
public struct IconButton: View {
    let symbol: String
    let help: String
    let size: CGFloat
    let tint: ColorToken
    let action: () -> Void

    /// `size`：Desktop 工具列 28、Mobile 導覽列 32–34
    public init(_ symbol: String, help: String, size: CGFloat = 28, tint: ColorToken = Palette.textSecondary,
                action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .hoverBackground()
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Chip、Pill

/// 類型篩選 chip。選取時為實心深色；未選取為 surface-raised + 邊框，圖示用類型顏色
public struct FilterChip: View {
    let title: String
    let symbol: String?
    let tint: ColorToken?
    let isSelected: Bool
    let action: () -> Void

    public init(_ title: String, symbol: String? = nil, tint: ColorToken? = nil, isSelected: Bool,
                action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Palette.bgCanvas) : AnyShapeStyle(tint ?? Palette.textSecondary))
                }
                Text(title)
                    .textStyle(.control)
                    .foregroundStyle(isSelected ? Palette.bgCanvas : Palette.textSecondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 11)
            .background(Capsule().fill(isSelected ? Palette.textPrimary : Palette.surfaceRaised))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Palette.border.color))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 小膠囊：「已儲存」狀態、文件標籤（可帶色點）
public struct Pill: View {
    let title: String
    let symbol: String?
    let dot: ColorToken?

    public init(_ title: String, symbol: String? = nil, dot: ColorToken? = nil) {
        self.title = title
        self.symbol = symbol
        self.dot = dot
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            Text(title).textStyle(.pill)
        }
        .foregroundStyle(Palette.textSecondary)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Palette.bgHover))
    }
}

// MARK: - 工具列元件

/// 網格 / 列表等以圖示切換的分段控制（設計稿的 View Toggle）
public struct IconSegmentedControl<Value: Hashable>: View {
    public struct Segment {
        let value: Value
        let symbol: String
        let help: String
        public init(_ value: Value, symbol: String, help: String) {
            self.value = value
            self.symbol = symbol
            self.help = help
        }
    }

    @Binding var selection: Value
    let segments: [Segment]

    public init(selection: Binding<Value>, segments: [Segment]) {
        _selection = selection
        self.segments = segments
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                let selected = segment.value == selection
                Button { selection = segment.value } label: {
                    Image(systemName: segment.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Palette.textPrimary : Palette.textTertiary)
                        .frame(width: 26, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Palette.surfaceRaised : Palette.bgHover)
                            .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(segment.help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.bgHover))
    }
}

/// 麵包屑：資料夾 / … / 目前項目
public struct Breadcrumb: View {
    let symbol: String
    let components: [String]

    public init(symbol: String = "folder", _ components: [String]) {
        self.symbol = symbol
        self.components = components
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
            ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                if index > 0 { Text("/").textStyle(.pageSubtitle).foregroundStyle(Palette.textTertiary) }
                let last = index == components.count - 1
                Text(name)
                    .textStyle(last ? .breadcrumb : .pageSubtitle)
                    .foregroundStyle(last ? Palette.textSecondary : Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
    }
}

/// 搜尋入口（按下開啟 ⌘K 快速開啟，不是輸入框）
public struct SearchFieldButton: View {
    public enum Size: Sendable { case sidebar, mobile }
    let placeholder: String
    let shortcut: String?
    let size: Size
    let action: () -> Void

    public init(_ placeholder: String, shortcut: String? = nil, size: Size = .sidebar, action: @escaping () -> Void) {
        self.placeholder = placeholder
        self.shortcut = shortcut
        self.size = size
        self.action = action
    }

    public var body: some View {
        let mobile = size == .mobile
        let shape = RoundedRectangle(cornerRadius: mobile ? Metrics.radiusMedium : Metrics.radiusSmall, style: .continuous)
        Button(action: action) {
            HStack(spacing: mobile ? 9 : 7) {
                Image(systemName: "magnifyingglass").font(.system(size: mobile ? 15 : 12))
                Text(placeholder).textStyle(mobile ? .mobileSearchField : .searchField)
                Spacer(minLength: 0)
                if let shortcut { Text(shortcut).textStyle(.pill) }
            }
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, mobile ? 13 : 9)
            .frame(height: mobile ? 42 : 30)
            .background(shape.fill(mobile ? Palette.bgSidebar : Palette.bgCanvas))
            .overlay(shape.strokeBorder(mobile ? Color.clear : Palette.border.color))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}
