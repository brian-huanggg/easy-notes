import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// 列表頁的排列方式與排序（工具列切換，列表頁讀取；每台裝置各自記住）
enum ListLayout: String { case grid, list }
enum ListSort: String { case modified, name }

/// 所有文件、最近、釘選、資料夾、標籤的列表頁。
/// 2.5b 只做導覽需要的骨架（標題 + 統計、子資料夾、文件網格 / 列表）；篩選、Pinned 區、真實預覽在 2.5c。
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

    var body: some View {
        let docs = documents
        let folders = subfolders
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(docs: docs.count, folders: folders.count)
                if docs.isEmpty && folders.isEmpty {
                    empty.frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    if !folders.isEmpty { folderSection(folders) }
                    if !docs.isEmpty { documentSection(docs) }
                }
            }
            .padding(.horizontal, style == .mobile ? 20 : Metrics.contentPadding)
            .padding(.top, style == .mobile ? 8 : 28)
            .padding(.bottom, style == .mobile ? 100 : 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bgCanvas)
        .task(id: TagQuery(route: route, files: store.files)) {
            if case .tag(let tag) = route { tagged = await store.files(taggedWith: tag) }
        }
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
        case .pinned: [] // 釘選的存放位置尚未決定（frontmatter 或 .easynotes/pins.json），見 Roadmap 2.5 待決事項
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

    // MARK: 標題

    private func header(docs: Int, folders: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.title(for: route))
                .textStyle(style == .mobile ? .largeTitle : .pageTitle)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Text(folders > 0 ? "\(docs) 份文件 · \(folders) 個資料夾" : "\(docs) 份文件")
                .textStyle(style == .mobile ? TextStyle(14) : .pageSubtitle)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.bottom, 24)
    }

    // MARK: 區段

    private func folderSection(_ folders: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("資料夾", symbol: "folder", detail: "\(folders.count)", size: style == .mobile ? .mobile : .desktop)
            if style == .mobile {
                VStack(spacing: 4) { ForEach(folders, id: \.self) { folderRow($0) } }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(folders, id: \.self) { folderRow($0) }
                }
            }
        }
        .padding(.bottom, 28)
    }

    private func folderRow(_ path: String) -> some View {
        Button { go(.folder(path)) } label: {
            DocRow((path as NSString).lastPathComponent, symbol: "folder", tint: .neutral,
                   meta: "\(store.fileCount(in: path)) 份文件", style: style == .mobile ? .list : .card)
        }
        .buttonStyle(.plain)
        .contextMenu { NodeMenu(path: path, isFolder: true) }
    }

    private func documentSection(_ docs: [IndexedFile]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("文件", symbol: "clock.arrow.circlepath", detail: "\(docs.count)",
                          size: style == .mobile ? .mobile : .desktop)
            if style == .mobile || layout == .list {
                LazyVStack(spacing: 4) {
                    ForEach(docs) { file in
                        cell(file) {
                            DocRow(store.displayName(file.path), symbol: symbol(file), tint: tint(file), meta: meta(file))
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Metrics.gridSpacing)],
                          spacing: Metrics.gridSpacing + 6) {
                    ForEach(docs) { file in
                        cell(file) {
                            DocCard(store.displayName(file.path), symbol: symbol(file), tint: tint(file), meta: meta(file))
                        }
                    }
                }
            }
        }
    }

    private func cell(_ file: IndexedFile, @ViewBuilder label: () -> some View) -> some View {
        Button { go(.file(file.path)) } label: { label() }
            .buttonStyle(.plain)
            .contextMenu { NodeMenu(path: file.path, isFolder: false) }
    }

    private func symbol(_ file: IndexedFile) -> String { store.plugins.symbol(for: store.kindID(file.path)) }
    private func tint(_ file: IndexedFile) -> KindTint { store.plugins.tint(for: store.kindID(file.path)) }
    private func meta(_ file: IndexedFile) -> String {
        "\(file.mtime.formatted(.relative(presentation: .named)))編輯"
    }

    private func go(_ target: Route) {
        if let open { open(target) } else { store.navigate(target) }
    }

    // MARK: 空狀態

    @ViewBuilder
    private var empty: some View {
        switch route {
        case .all:
            EmptyState("Vault 是空的", message: "建立第一份文件，或把檔案放進 \(store.fs.root.path(percentEncoded: false))。",
                       symbol: "doc.text") { NewFileButtons() }
        case .folder(let folder):
            EmptyState("這個資料夾是空的", message: "\(store.vaultName)/\(folder)", symbol: "folder", style: .dropZone) {
                NewFileButtons()
            }
        case .pinned:
            EmptyState("還沒有釘選的文件", message: "釘選功能會在文件列表與編輯器加入。", symbol: "pin", style: .dropZone) {}
        default:
            EmptyState("沒有文件", message: "", symbol: "doc", style: .dropZone) {}
        }
    }
}

/// 空狀態的建立按鈕：第一個是主要按鈕，其餘次要；項目來自 Registry
struct NewFileButtons: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        ForEach(Array(store.plugins.newFileCommands.enumerated()), id: \.element.id) { index, command in
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
