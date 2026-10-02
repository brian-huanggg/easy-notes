import EasyNotesCore
import EasyNotesUI
import SwiftUI

#if os(iOS)
/// iPhone：底部浮動分頁（`C/M Tab Bar`）取代 NavigationSplitView 的摺疊行為。
/// 每個分頁各有一個導覽堆疊；資料夾點下去是推入下一層，不會跳到空白頁
struct PhoneShell: View {
    enum Tab: Hashable { case docs, search, spaces, me }

    @Environment(VaultStore.self) private var store
    @State private var tab = Tab.docs
    @State private var docsPath: [Route] = []
    @State private var searchPath: [Route] = []
    @State private var spacesPath: [Route] = []

    var body: some View {
        TabView(selection: $tab) {
            stack($docsPath) { PhoneDocs(push: push) }.tag(Tab.docs)
            stack($searchPath) { QuickOpen(open: { push(.file($0)) }).navigationTitle("搜尋") }.tag(Tab.search)
            stack($spacesPath) { PhoneSpaces(push: push) }.tag(Tab.spaces)
            NavigationStack { MeView() }.tag(Tab.me).toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom) {
            if currentPath.isEmpty {
                TabBar(selection: $tab, items: [
                    .init(.docs, title: "文件", symbol: "doc.text"),
                    .init(.search, title: "搜尋", symbol: "magnifyingglass"),
                    .init(.spaces, title: "空間", symbol: "square.stack.3d.up"),
                    .init(.me, title: "我", symbol: "person.crop.circle"),
                ])
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: currentPath.isEmpty)
        // 從編輯器內的 [[連結]]、新增檔案等改變位置時，推入目前分頁
        .onChange(of: store.route) { _, route in
            switch route {
            case .file, .folder: if currentPath.last != route { push(route) }
            default: break
            }
        }
    }

    private var currentPath: [Route] {
        switch tab {
        case .docs: docsPath
        case .search: searchPath
        case .spaces: spacesPath
        case .me: []
        }
    }

    private func push(_ route: Route) {
        switch tab {
        case .docs: docsPath.append(route)
        case .search: searchPath.append(route)
        case .spaces: spacesPath.append(route)
        case .me: break
        }
    }

    private func stack(_ path: Binding<[Route]>, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: path) {
            root()
                .navigationDestination(for: Route.self) { route in
                    PhoneDestination(route: route, push: push)
                }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

/// 推入的頁面；出現時把 `store.route` 換成自己（不記入歷史），讓新增檔案等作用在目前位置
private struct PhoneDestination: View {
    @Environment(VaultStore.self) private var store
    let route: Route
    let push: (Route) -> Void

    var body: some View {
        content
            .onAppear { store.replace(with: route) }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .file(let path):
            Group {
                if let editor = store.plugins.editor(for: store.kindID(path), path: path) { editor }
                else { ContentUnavailableView("不支援的檔案類型", systemImage: "doc.questionmark") }
            }
            .navigationTitle(store.displayName(path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 設計稿：中間是儲存狀態（標題已在文件頭），右側釘選、分享、更多
                ToolbarItem(placement: .principal) { DocumentStatusPill(path: path) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PinButton(path: path)
                    ShareLink(item: store.fs.url(for: path)) { Label("分享", systemImage: "square.and.arrow.up") }
                    DocumentMoreMenu(path: path)
                }
            }
        case .panel(let id):
            if let panel = store.plugins.panel(id: id) { panel.content().navigationTitle(panel.title) }
        default:
            DocumentList(route: route, style: .mobile, open: push)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { PhoneNewMenu() } }
        }
    }
}

/// 文件分頁：Vault 標頭 + 所有文件
private struct PhoneDocs: View {
    @Environment(VaultStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    let push: (Route) -> Void

    var body: some View {
        DocumentList(route: .all, style: .mobile, open: push)
            .onAppear { store.replace(with: .all) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VaultHeader(name: store.vaultName, account: nil, icon: Image("AppLogo")).fixedSize()
                }
                ToolbarItem(placement: .topBarTrailing) { PhoneNewMenu() }
            }
            .toolbarBackground(Palette.bgCanvas, for: .navigationBar)
    }
}

/// Spaces 分頁：所有文件 / 最近 / 釘選、外掛面板、第一層資料夾
private struct PhoneSpaces: View {
    @Environment(VaultStore.self) private var store
    let push: (Route) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("空間").textStyle(.largeTitle).foregroundStyle(Palette.textPrimary)
                    Spacer()
                    IconButton("plus", help: "新增空間", size: 34) { store.createSpace() }
                }
                HStack(spacing: 10) {
                    tile(.all, detail: "\(store.files.count) 份文件")
                    tile(.recents, detail: "依修改時間")
                    tile(.pinned, detail: "釘選的文件")
                }
                ForEach(store.plugins.panels) { panel in
                    Button { push(.panel(panel.id)) } label: {
                        SidebarItem(panel.title, symbol: panel.symbol, count: panel.badge(), countTint: panel.badgeTint)
                    }
                    .buttonStyle(.plain)
                }
                let spaces = store.tree.filter(\.isFolder)
                SectionHeader("空間", symbol: "square.stack.3d.up", detail: "\(spaces.count)", size: .mobile)
                VStack(spacing: 4) {
                    ForEach(spaces) { folder in
                        Button { push(.folder(folder.path)) } label: {
                            DocRow(folder.name, symbol: "folder", tint: .neutral, meta: "\(store.fileCount(in: folder.path)) 份文件")
                        }
                        .buttonStyle(.plain)
                        .contextMenu { NodeMenu(path: folder.path, isFolder: true) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
        .background(Palette.bgCanvas)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { store.replace(with: .all) }
    }

    private func tile(_ route: Route, detail: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
        return Button { push(route) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: store.symbol(for: route)).font(.system(size: 18)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.title(for: route)).textStyle(.rowTitle).foregroundStyle(Palette.textPrimary)
                    Text(detail).textStyle(.rowMeta).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(shape.fill(Palette.bgPanel))
            .overlay(shape.strokeBorder(Palette.border))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

/// iPhone 導覽列的「+」：與 Desktop 的 New Document 選單相同的項目
private struct PhoneNewMenu: View {
    @Environment(VaultStore.self) private var store
    @Environment(ShellState.self) private var shell

    var body: some View {
        Menu("新增文件", systemImage: "plus") { NewDocumentItems(store: store, shell: shell) }
    }
}
#endif
