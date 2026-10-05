import SwiftUI

/// Design `C/Sidebar Item`: icon 16, title 13 medium, count on the right.
/// When selected: `bg-selected` background, accent text; `indent` is for child files after expanding a folder.
public struct SidebarItem: View {
    let title: String
    let symbol: String
    let symbolTint: ColorToken?
    let count: Int?
    let countTint: ColorToken?
    let isSelected: Bool
    let indent: Int

    /// `symbolTint`: files use the type color; nil = text-secondary. `countTint`: for example the review count uses `card-due`
    public init(_ title: String, symbol: String, symbolTint: ColorToken? = nil, count: Int? = nil,
                countTint: ColorToken? = nil, isSelected: Bool = false, indent: Int = 0) {
        self.title = title
        self.symbol = symbol
        self.symbolTint = symbolTint
        self.count = count
        self.countTint = countTint
        self.isSelected = isSelected
        self.indent = indent
    }

    public var body: some View {
        let child = indent > 0
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: child ? 12 : 14))
                .foregroundStyle(isSelected ? Palette.accent : symbolTint ?? Palette.textSecondary)
                .frame(width: 16, height: 16)
            Text(title)
                .textStyle(child ? .control : .sidebarItem)
                .foregroundStyle(isSelected ? Palette.accent : child ? Palette.textSecondary : Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let count {
                Text("\(count)")
                    .textStyle(.metaMedium)
                    .monospacedDigit()
                    .foregroundStyle(countTint ?? Palette.textTertiary)
            }
        }
        .padding(.vertical, child ? 5.5 : 7)
        .padding(.leading, 9 + CGFloat(indent) * 14)
        .padding(.trailing, 9)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
            .fill(isSelected ? Palette.bgSelected : ColorToken.clear))
        .hoverBackground(isActive: !isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Sidebar section headings "SPACES" and "TAGS", with an action on the right (new folder, manage tags)
public struct SidebarGroupLabel: View {
    let title: String
    let actionSymbol: String?
    let actionHelp: String
    let action: (() -> Void)?

    public init(_ title: String, actionSymbol: String? = nil, actionHelp: String = "", action: (() -> Void)? = nil) {
        self.title = title
        self.actionSymbol = actionSymbol
        self.actionHelp = actionHelp
        self.action = action
    }

    public var body: some View {
        HStack {
            Text(title).textStyle(.groupLabel).foregroundStyle(Palette.textTertiary)
            Spacer()
            if let actionSymbol, let action {
                Button(action: action) {
                    Image(systemName: actionSymbol).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(actionHelp)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 9)
    }
}

/// Vault header: icon (the app-provided logo; the name's first character if none) + vault name + account. A single vault, not switchable
public struct VaultHeader: View {
    let name: String
    let account: String?
    let icon: Image?

    public init(name: String, account: String?, icon: Image? = nil) {
        self.name = name
        self.account = account
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 9) {
            badge
            VStack(alignment: .leading, spacing: 1) {
                Text(name).textStyle(.sectionTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                if let account {
                    Text(account).textStyle(.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 7)
    }

    @ViewBuilder private var badge: some View {
        if let icon {
            icon.resizable().scaledToFit()
                .frame(width: 24, height: 24)
        } else {
            Text(name.prefix(1).uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.accent))
        }
    }
}

/// Two-line status row: icon + title + small text (sync status "Synced · 2 min ago")
public struct StatusRow: View {
    let symbol: String
    let tint: ColorToken
    let title: String
    let detail: String?

    public init(_ title: String, detail: String? = nil, symbol: String, tint: ColorToken = Palette.textSecondary) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(tint).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).textStyle(.sidebarItem).foregroundStyle(Palette.textSecondary)
                if let detail { Text(detail).textStyle(.caption).foregroundStyle(Palette.textTertiary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .hoverBackground()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Section heading "📌 Pinned 4 ……… See all"
public struct SectionHeader: View {
    let title: String
    let symbol: String
    let detail: String?
    let actionTitle: String?
    let action: (() -> Void)?
    let size: Size

    public enum Size: Sendable { case desktop, mobile }

    public init(_ title: String, symbol: String, detail: String? = nil, size: Size = .desktop,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.size = size
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        let mobile = size == .mobile
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
            Text(title)
                .textStyle(TextStyle(mobile ? 13.5 : 13, .semibold))
                .foregroundStyle(Palette.textPrimary)
            if let detail {
                Text(detail).textStyle(TextStyle(mobile ? 12.5 : 12)).foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .textStyle(TextStyle(mobile ? 12.5 : 12, .medium))
                    .foregroundStyle(Palette.accent)
            }
        }
    }
}
