import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// 內容區上方的分頁列（Mac / iPad）：只有一個分頁時不顯示
struct DocumentTabBar: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.tabs.tabs) { tab in
                        DocumentTabItem(tab: tab, route: store.tabRoute(tab), isActive: tab.id == store.tabs.activeID)
                    }
                }
                .padding(.horizontal, 8)
            }
            Button(L("新分頁"), systemImage: "plus") { store.newTab() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary.color)
                .padding(.horizontal, 10)
                .help(L("新分頁（⌘T）"))
                .accessibilityIdentifier(A11yID.Tabs.new)
        }
        .frame(height: 34)
        .background(Palette.bgSidebar.color)
        .overlay(alignment: .bottom) { Palette.border.color.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Tabs.bar)
    }
}

private struct DocumentTabItem: View {
    @Environment(VaultStore.self) private var store
    let tab: TabSet<VaultStore.TabState>.Tab
    let route: Route
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        let key = route.filePath ?? String(describing: route)
        HStack(spacing: 6) {
            Image(systemName: store.symbol(for: route))
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary.color)
            Text(title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle((isActive ? Palette.textPrimary : Palette.textSecondary).color)
                .lineLimit(1)
            Button(L("關閉分頁"), systemImage: "xmark") { store.closeTab(tab.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.textTertiary.color)
                .opacity(isActive || hovering ? 1 : 0)
                .help(L("關閉分頁（⌘W）"))
                .accessibilityIdentifier(A11yID.Tabs.close(key))
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 90, maxWidth: 200, minHeight: 26)
        .background(isActive ? Palette.bgCanvas.color : (hovering ? Palette.bgHover.color : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.activateTab(tab.id) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("關閉分頁")) { store.closeTab(tab.id) }
            Button(L("關閉其他分頁")) { store.closeOtherTabs(keeping: tab.id) }
                .disabled(store.tabs.tabs.count < 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(A11yID.Tabs.tab(key))
    }

    private var title: String { store.title(for: route) }
}
