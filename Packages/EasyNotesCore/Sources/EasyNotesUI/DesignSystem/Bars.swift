import SwiftUI

/// Design `C/M Tab Bar`: the iPhone bottom floating tab bar (translucent + blur + shadow), selected item on an accent-soft background
public struct TabBar<ID: Hashable>: View {
    public struct Item {
        let id: ID
        let title: String
        let symbol: String
        public init(_ id: ID, title: String, symbol: String) {
            self.id = id
            self.title = title
            self.symbol = symbol
        }
    }

    @Binding var selection: ID
    let items: [Item]

    public init(selection: Binding<ID>, items: [Item]) {
        _selection = selection
        self.items = items
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let selected = item.id == selection
                Button { selection = item.id } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 18))
                        Text(item.title).textStyle(selected ? .tabLabelSelected : .tabLabel)
                    }
                    .foregroundStyle(selected ? Palette.accent : Palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Capsule().fill(selected ? Palette.accentSoft : ColorToken.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(height: 56)
        .glassBackground(Capsule())
    }
}

/// A toolbar button: icon + help + action; with `menu` it expands a menu on press (items titled by `help`)
public struct ToolItem: Identifiable {
    public var id: String { symbol + help }
    let symbol: String
    let help: String
    let isActive: Bool
    let menu: [ToolItem]?
    let action: () -> Void

    public init(_ symbol: String, help: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.isActive = isActive
        self.menu = nil
        self.action = action
    }

    public init(_ symbol: String, help: String, menu: [ToolItem]) {
        self.symbol = symbol
        self.help = help
        self.isActive = false
        self.menu = menu
        self.action = {}
    }
}

/// Format toolbar. `.floating`: the floating capsule at the lower right of the Desktop editor; `.keyboard`: the Format Bar above the iOS keyboard, with dismiss-keyboard on the right
public struct FormatBar: View {
    public enum Style: Sendable { case floating, keyboard }

    let items: [ToolItem]
    let style: Style
    let dismiss: ToolItem?

    public init(_ items: [ToolItem], style: Style, dismiss: ToolItem? = nil) {
        self.items = items
        self.style = style
        self.dismiss = dismiss
    }

    public var body: some View {
        let floating = style == .floating
        HStack(spacing: floating ? 2 : 4) {
            ForEach(items) { button($0) }
            if let dismiss {
                Spacer(minLength: 0)
                button(dismiss, tint: Palette.textTertiary)
            }
        }
        .padding(.horizontal, floating ? 8 : 14)
        .frame(height: floating ? 44 : 52)
        .modifier(FormatBarBackground(style: style))
    }

    private func button(_ item: ToolItem, tint: ColorToken = Palette.textSecondary) -> some View {
        let floating = style == .floating
        let size: CGFloat = floating ? 32 : 36
        let label = Image(systemName: item.symbol)
            .font(.system(size: floating ? 15 : 16))
            .foregroundStyle(item.isActive ? Palette.accent : tint)
            .frame(width: size, height: size)
            .background {
                if floating { Circle().fill(item.isActive ? Palette.accentSoft : ColorToken.clear) }
                else { RoundedRectangle(cornerRadius: Metrics.radiusSmall).fill(item.isActive ? Palette.accentSoft : ColorToken.clear) }
            }
            .contentShape(Rectangle())
            .hoverBackground(cornerRadius: floating ? size / 2 : Metrics.radiusSmall, isActive: !item.isActive)
        return Group {
            if let menu = item.menu {
                Menu {
                    ForEach(menu) { entry in Button(entry.help, systemImage: entry.symbol, action: entry.action) }
                } label: {
                    label
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button(action: item.action) { label }
            }
        }
        .buttonStyle(.plain)
        .help(item.help)
        .accessibilityLabel(item.help)
    }
}

private struct FormatBarBackground: ViewModifier {
    let style: FormatBar.Style

    func body(content: Content) -> some View {
        switch style {
        case .floating:
            content.glassBackground(Capsule())
        case .keyboard:
            let shape = RoundedRectangle(cornerRadius: Metrics.radiusBar, style: .continuous)
            content
                .background(shape.fill(Palette.bgPanel))
                .overlay(shape.strokeBorder(Palette.border))
        }
    }
}

public extension View {
    /// The background of floating elements: surface-glass + blur + border + soft shadow (Tab Bar, floating format toolbar)
    func glassBackground<S: InsettableShape>(_ shape: S) -> some View {
        background {
            shape.fill(.ultraThinMaterial)
            shape.fill(Palette.surfaceGlass)
        }
        .overlay(shape.strokeBorder(Palette.border))
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 6)
    }
}
