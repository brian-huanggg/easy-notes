import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// 列表頁的排列方式與排序（工具列切換，列表頁讀取；每台裝置各自記住）
enum ListLayout: String { case grid, list }
enum ListSort: String { case modified, name }

/// 所有文件、最近、釘選、資料夾、標籤的列表頁（設計稿 `RZ0Lk` / `CIaUn`）：
/// 標題 + 統計、類型篩選、釘選區、子資料夾、文件區。類型、顏色、縮圖都來自 Registry。
struct DocumentList: View {
    enum Style { case desktop, mobile }

    @Environment(VaultStore.self) private var store
    @AppStorage("listLayout") private var layout = ListLayout.grid
    @AppStorage("listSort") private var sort = ListSort.modified
    let route: Route
    var style = Style.desktop
    /// iPhone：由導覽堆疊推入頁面；Desktop：改變 `store.route`
    var open: ((Route) -> Void)?

    @State private var tagged: [IndexedFile] = []
    /// 類型篩選（Kind id）；nil = 全部
    @State private var filter: String?
    @State private var isDropTargeted = false

    /// Desktop 釘選區只顯示一列，其餘在「釘選」頁
    private static let pinnedLimit = 4

    private var mobile: Bool { style == .mobile }

    var body: some View {
        let docs = documents
        let folders = subfolders
        let visible = filter.map { kind in docs.filter { store.kindID($0.path) == kind } } ?? docs
        let pinned = showsPinnedSection ? visible.filter(\.pinned) : []
        let rest = showsPinnedSection ? visible.filter { !$0.pinned } : visible
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(docs: docs.count, folders: folders.count)
                if isEmptyVault(docs: docs, folders: folders) {
                    emptyVault.frame(maxWidth: .infinity).padding(.top, mobile ? 40 : 120)
                } else {
                    filterBar
                    if !pinned.isEmpty { pinnedSection(pinned) }
                    if !folders.isEmpty { folderSection(folders) }
                    if docs.isEmpty && folders.isEmpty {
                        empty.frame(maxWidth: .infinity).padding(.top, 40)
                    } else if visible.isEmpty && !docs.isEmpty {
                        noMatch.frame(maxWidth: .infinity).padding(.top, 40)
                    } else if !rest.isEmpty {
                        documentSection(rest)
                    }
                }
            }
            .padding(.horizontal, mobile ? 20 : Metrics.contentPadding)
            .padding(.top, mobile ? 8 : 22)
            .padding(.bottom, mobile ? 100 : 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bgCanvas)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Metrics.radiusLarge).strokeBorder(Palette.accent, lineWidth: 2).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = dropFolder else { return false }
            Task { _ = await store.importDropped(urls, into: folder) }
            return urls.contains { store.fs.kinds.kind(for: $0) != nil }
        } isTargeted: { isDropTargeted = $0 && dropFolder != nil }
        .task(id: TagQuery(route: route, files: store.files)) {
            if case .tag(let tag) = route { tagged = await store.files(taggedWith: tag) }
        }
        .onChange(of: route) { filter = nil }
    }

    private struct TagQuery: Equatable {
        let route: Route
        let files: [IndexedFile]
    }

    // MARK: 資料

    private var documents: [IndexedFile] {
        let files: [IndexedFile] = switch route {
        case .all: store.files
        case .recents: Array(store.files.prefix(30))
        case .pinned: store.files.filter(\.pinned)
        case .folder(let folder): store.files.filter { ($0.path as NSString).deletingLastPathComponent == folder }
        case .tag: tagged
        case .file, .panel: []
        }
        // 最近：永遠依修改時間
        guard sort == .name, route != .recents else { return files }
        return files.sorted { store.displayName($0.path).localizedStandardCompare(store.displayName($1.path)) == .orderedAscending }
    }

    private var subfolders: [String] {
        guard case .folder(let folder) = route else { return [] }
        return (store.node(at: folder)?.children ?? []).filter(\.isFolder).map(\.path)
    }

    /// 所有文件與資料夾頁把釘選的文件放在上方的釘選區
    private var showsPinnedSection: Bool {
        switch route {
        case .all, .folder: true
        default: false
        }
    }

    /// 可以拖入檔案的資料夾：Vault 根目錄（所有文件）或目前資料夾
    private var dropFolder: String? {
        switch route {
        case .all: ""
        case .folder(let folder): folder
        default: nil
        }
    }

    private func isEmptyVault(docs: [IndexedFile], folders: [String]) -> Bool {
        route == .all && docs.isEmpty && store.tree.isEmpty
    }

    // MARK: 標題

    private func header(docs: Int, folders: Int) -> some View {
        VStack(alignment: .leading, spacing: mobile ? 5 : 5) {
            Text(store.title(for: route))
                .textStyle(mobile ? .largeTitle : .pageTitle)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier(A11yID.List.title)
            Text(subtitle(docs: docs, folders: folders))
                .textStyle(mobile ? TextStyle(13) : .pageSubtitle)
                .foregroundStyle(mobile ? Palette.textSecondary : Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier(A11yID.List.subtitle)
        }
        .padding(.bottom, mobile ? 18 : 26)
    }

    private func subtitle(docs: Int, folders: Int) -> String {
        switch route {
        case .all:
            let spaces = store.tree.count(where: \.isFolder)
            return spaces > 0 ? L("\(docs) 份文件 · \(spaces) 個空間") : L("\(docs) 份文件")
        case .folder(let folder) where docs == 0 && folders == 0:
            return L("空資料夾 · \(store.vaultName)/\(folder)")
        default:
            return folders > 0 ? L("\(docs) 份文件 · \(folders) 個資料夾") : L("\(docs) 份文件")
        }
    }

    // MARK: 篩選

    /// 全部 + Registry 中已註冊的類型；尚未實作的外掛不會出現
    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: mobile ? 8 : 6) {
                FilterChip(L("全部"), isSelected: filter == nil) { filter = nil }
                    .accessibilityIdentifier(A11yID.List.filterAll)
                ForEach(store.plugins.kindInfos) { info in
                    FilterChip(info.name, symbol: info.symbol, tint: info.tint.base, isSelected: filter == info.id) {
                        filter = filter == info.id ? nil : info.id
                    }
                    .accessibilityIdentifier(A11yID.List.filter(info.id))
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, mobile ? 20 : 26)
    }

    // MARK: 區段

    private func pinnedSection(_ pinned: [IndexedFile]) -> some View {
        VStack(alignment: .leading, spacing: mobile ? 13 : 14) {
            SectionHeader(L("釘選"), symbol: "pin", detail: "\(pinned.count)", size: mobile ? .mobile : .desktop,
                          actionTitle: L("查看全部")) { go(.pinned) }
            if mobile {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(pinned) { file in cell(file) { card(file, size: .compact) } }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -20)
                .contentMargins(.horizontal, 20, for: .scrollContent)
            } else {
                grid(Array(pinned.prefix(Self.pinnedLimit)))
            }
        }
        .padding(.bottom, mobile ? 20 : 26)
    }

    private func folderSection(_ folders: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("資料夾"), symbol: "folder", detail: "\(folders.count)", size: mobile ? .mobile : .desktop)
            if mobile {
                VStack(spacing: 4) { ForEach(folders, id: \.self) { folderRow($0) } }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(folders, id: \.self) { folderRow($0) }
                }
            }
        }
        .padding(.bottom, mobile ? 20 : 26)
    }

    private func folderRow(_ path: String) -> some View {
        Button { go(.folder(path)) } label: {
            DocRow((path as NSString).lastPathComponent, symbol: "folder", tint: .neutral,
                   meta: L("\(store.fileCount(in: path)) 份文件"), style: mobile ? .list : .card)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.List.folder(path))
        .contextMenu { NodeMenu(path: path, isFolder: true) }
    }

    private func documentSection(_ docs: [IndexedFile]) -> some View {
        VStack(alignment: .leading, spacing: mobile ? 4 : 14) {
            Group {
                if mobile {
                    SectionHeader(sectionTitle, symbol: sectionSymbol, detail: "\(docs.count)", size: .mobile,
                                  actionTitle: sort == .modified ? L("依名稱") : L("依時間")) {
                        sort = sort == .modified ? .name : .modified
                    }
                } else {
                    SectionHeader(sectionTitle, symbol: sectionSymbol, detail: "\(docs.count)")
                }
            }
            .padding(.bottom, mobile ? 6 : 0)
            if mobile || layout == .list {
                LazyVStack(spacing: mobile ? 0 : 4) {
                    ForEach(docs) { file in
                        cell(file) {
                            DocRow(title(file), symbol: symbol(file), tint: tint(file), meta: meta(file))
                        }
                    }
                }
            } else {
                grid(docs)
            }
        }
    }

    private var sectionTitle: String {
        if route == .pinned { return L("釘選") }
        return sort == .modified || route == .recents ? L("最近") : L("文件")
    }

    private var sectionSymbol: String {
        if route == .pinned { return "pin" }
        return sort == .modified || route == .recents ? "clock.arrow.circlepath" : "doc.on.doc"
    }

    /// Desktop 網格：卡片寬約 234（設計稿每列 4 張）
    private func grid(_ docs: [IndexedFile]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Metrics.gridSpacing, alignment: .top)],
                  spacing: Metrics.gridSpacing) {
            ForEach(docs) { file in cell(file) { card(file, size: .regular) } }
        }
    }

    private func card(_ file: IndexedFile, size: DocCard<CardPreview>.Size) -> some View {
        DocCard(title(file), symbol: symbol(file), tint: tint(file), meta: meta(file), size: size) {
            CardPreview(file: file, scale: size == .compact ? 0.7 : 1)
        }
    }

    private func cell(_ file: IndexedFile, @ViewBuilder label: () -> some View) -> some View {
        Button { go(.file(file.path)) } label: { label() }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.List.document(file.path))
            .contextMenu { NodeMenu(path: file.path, isFolder: false) }
    }

    /// frontmatter 的 emoji icon 放在標題前；SF Symbol icon 取代類型圖示（見 `symbol(_:)`）
    private func title(_ file: IndexedFile) -> String {
        let name = store.displayName(file.path)
        return DocIcon(file.icon)?.emoji.map { "\($0) \(name)" } ?? name
    }

    private func symbol(_ file: IndexedFile) -> String {
        DocIcon(file.icon)?.symbolName ?? store.plugins.symbol(for: store.kindID(file.path))
    }
    private func tint(_ file: IndexedFile) -> KindTint { store.plugins.tint(for: store.kindID(file.path)) }

    /// 外掛的一行摘要 + 相對時間：「1,240 字 · 2 小時前」
    private func meta(_ file: IndexedFile) -> String {
        [file.summary, file.mtime.formatted(.relative(presentation: .named))].compactMap(\.self).joined(separator: " · ")
    }

    private func go(_ target: Route) {
        if let open { open(target) } else { store.navigate(target) }
    }

    // MARK: 空狀態

    /// 設計稿 `xGsaX`
    private var emptyVault: some View {
        EmptyState(L("Vault 是空的"),
                   message: L("所有內容都是磁碟上的一般檔案。建立第一份筆記或白板，或把檔案拖進來。"),
                   symbol: "doc.text") {
            NewFileButtons(limit: 2)
            #if os(macOS)
            Button(revealTitle, systemImage: "folder") { reveal(store.fs.root) }.buttonStyle(.enSecondary(size: .large))
            #endif
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch route {
        case .folder:
            // 設計稿 `m4Bb4`：可拖入檔案的空資料夾
            EmptyState(L("這個資料夾是空的"), message: L("把檔案拖到這裡，或在這個資料夾中建立新文件。"), symbol: "folder",
                       style: .dropZone) {
                NewFileButtons(limit: 2)
            }
        case .pinned:
            EmptyState(L("還沒有釘選的文件"), message: L("在文件上按右鍵（或長按）選擇「釘選」。"), symbol: "pin", style: .dropZone) {}
        default:
            EmptyState(L("沒有文件"), message: "", symbol: "doc", style: .dropZone) {}
        }
    }

    private var noMatch: some View {
        EmptyState(L("沒有符合的文件"), message: L("這裡沒有這個類型的文件。"), symbol: "line.3.horizontal.decrease",
                   style: .dropZone) {
            Button(L("顯示全部")) { filter = nil }.buttonStyle(.enSecondary(size: .large))
        }
    }
}

/// 卡片縮圖：外掛註冊的預覽（依內容 hash 快取、背景產生），載入前與沒有預覽的類型顯示骨架佔位
private struct CardPreview: View {
    @Environment(VaultStore.self) private var store
    let file: IndexedFile
    let scale: CGFloat
    @State private var preview: DocumentPreview?

    var body: some View {
        let provider = store.plugins.preview(for: store.kindID(file.path))
        Group {
            if let provider, let preview {
                provider.view(preview, scale: scale)
            } else {
                SkeletonPreview(scale: scale)
            }
        }
        .task(id: file.hash) { preview = await store.preview(for: file) }
    }
}

/// 空狀態的建立按鈕：第一個是主要按鈕，其餘次要；項目來自 Registry
struct NewFileButtons: View {
    @Environment(VaultStore.self) private var store
    var limit = Int.max

    var body: some View {
        ForEach(Array(store.plugins.newFileCommands.prefix(limit).enumerated()), id: \.element.id) { index, command in
            let button = Button(command.title, systemImage: command.symbol) {
                store.create(command.kind, title: command.defaultName)
            }
            if index == 0 { button.buttonStyle(.enPrimary(size: .large)) }
            else { button.buttonStyle(.enSecondary(size: .large)) }
        }
    }
}

extension VaultStore {
    /// 檔案樹中 `path` 的節點
    func node(at path: String) -> VaultNode? {
        func find(_ nodes: [VaultNode]) -> VaultNode? {
            for node in nodes {
                if node.path == path { return node }
                if path.hasPrefix(node.path + "/"), let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(tree)
    }
}
