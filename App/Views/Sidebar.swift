import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// 設計稿 `C/Sidebar Desktop`（`YXFMc`）：Vault 標頭、搜尋、導覽、Spaces、Tags，底部是最近刪除、同步狀態、設定。
/// 外掛的項目（`addPanel`）接在 All Documents 之後；App 不寫死任何外掛。
struct Sidebar: View {
    @Environment(VaultStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @Environment(ShellState.self) private var shell
    /// 展開中的資料夾（Spaces 檔案樹）
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VaultHeader(name: store.vaultName, account: sync.accountEmail, icon: Image("AppLogo"))
                        .padding(.bottom, 10)
                    SearchFieldButton("搜尋", shortcut: "⌘K") { shell.showQuickOpen = true }
                        .padding(.bottom, 12)
                    navigation
                    spaces.padding(.top, 18)
                    if !store.tags.isEmpty { tags.padding(.top, 18) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            footer
        }
        .background(Palette.bgSidebar)
        .onChange(of: store.route) { _, route in reveal(route) }
    }

    // MARK: 導覽

    private var navigation: some View {
        VStack(spacing: 1) {
            item(.all, "所有文件", symbol: "doc.text", count: store.files.count)
            ForEach(store.plugins.panels) { panel in
                item(.panel(panel.id), panel.title, symbol: panel.symbol, count: panel.badge(), countTint: panel.badgeTint)
            }
            item(.recents, "最近", symbol: "clock.arrow.circlepath")
            item(.pinned, "釘選", symbol: "pin", count: pinnedCount)
        }
    }

    private var pinnedCount: Int? {
        let count = store.files.count(where: \.pinned)
        return count > 0 ? count : nil
    }

    private func item(_ route: Route, _ title: String, symbol: String, count: Int? = nil,
                      countTint: ColorToken? = nil) -> some View {
        Button { store.navigate(route) } label: {
            SidebarItem(title, symbol: symbol, count: count, countTint: countTint, isSelected: store.route == route)
        }
        .buttonStyle(.plain)
    }

    // MARK: Spaces = 第一層資料夾

    private var spaces: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarGroupLabel("空間", actionSymbol: "plus", actionHelp: "新增空間") { store.createSpace() }
            ForEach(store.tree.filter(\.isFolder)) { folder in
                node(folder, depth: 0)
            }
        }
    }

    private func node(_ node: VaultNode, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            row(node, depth: depth)
            if node.isFolder, expanded.contains(node.path) {
                ForEach(node.children ?? []) { child in
                    self.node(child, depth: depth + 1)
                }
            }
        })
    }

    private func row(_ node: VaultNode, depth: Int) -> some View {
        let route: Route = node.isFolder ? .folder(node.path) : .file(node.path)
        let kind = store.kindID(node.path)
        return Button { open(node) } label: {
            SidebarItem(node.isFolder ? node.name : store.displayName(node.path),
                        symbol: node.isFolder ? (expanded.contains(node.path) ? "folder.fill" : "folder")
                                              : store.plugins.symbol(for: kind),
                        symbolTint: node.isFolder ? nil : store.plugins.tint(for: kind).base,
                        count: node.isFolder && depth == 0 ? store.fileCount(in: node.path) : nil,
                        isSelected: store.route == route, indent: depth)
        }
        .buttonStyle(.plain)
        .contextMenu { NodeMenu(path: node.path, isFolder: node.isFolder) }
    }

    /// 點資料夾：開啟資料夾頁並展開；再點一次已選取的資料夾則收合
    private func open(_ node: VaultNode) {
        guard node.isFolder else { return store.navigate(.file(node.path)) }
        if store.route == .folder(node.path) {
            if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
        } else {
            expanded.insert(node.path)
            store.navigate(.folder(node.path))
        }
    }

    /// 從別處（⌘K、連結、上一頁）開啟的檔案：展開它所在的資料夾
    private func reveal(_ route: Route) {
        guard case .file(let path) = route else { return }
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            expanded.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    // MARK: Tags

    private var tags: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarGroupLabel("標籤")
            ForEach(store.tags) { tag in
                item(.tag(tag.tag), tag.tag, symbol: "number", count: tag.count)
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { shell.showRecentlyDeleted = true } label: {
                StatusRow("最近刪除", detail: "保留 \(SyncEngine.retentionDays) 天", symbol: "trash")
            }
            .buttonStyle(.plain)
            SyncStatusRow()
            SettingsButton()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// 設定：macOS 開啟 Settings 視窗，iOS 以 sheet 顯示
private struct SettingsButton: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        #if os(macOS)
        SettingsLink { label }.buttonStyle(.plain)
        #else
        Button { shell.showSettings = true } label: { label }.buttonStyle(.plain)
        #endif
    }

    private var label: some View {
        SidebarItem("設定", symbol: "gearshape")
    }
}

/// 檔案與資料夾的右鍵選單：重新命名、在 Finder 中顯示、移到垃圾桶
struct NodeMenu: View {
    @Environment(VaultStore.self) private var store
    @Environment(ShellState.self) private var shell
    let path: String
    let isFolder: Bool

    var body: some View {
        Button("重新命名", systemImage: "pencil") {
            shell.rename(path, current: isFolder ? (path as NSString).lastPathComponent : store.displayName(path))
        }
        if !isFolder, let file = store.file(at: path), store.fs.kinds.kind(for: path)?.supportsPinning == true {
            Button(file.pinned ? "取消釘選" : "釘選", systemImage: file.pinned ? "pin.slash" : "pin") {
                Task { await store.setPinned(path, !file.pinned) }
            }
        }
        Button(revealTitle, systemImage: "folder") { reveal(store.fs.url(for: path)) }
        Divider()
        Button("移到垃圾桶", systemImage: "trash", role: .destructive) {
            Task { await store.delete(path) }
        }
    }
}
