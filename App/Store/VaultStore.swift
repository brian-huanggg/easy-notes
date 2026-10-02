import EasyNotesCore
import EasyNotesUI
import Foundation
import Observation

/// App 層的 Vault 狀態：檔案樹、選取、搜尋、反向連結、標籤。
/// 所有內容都存在檔案裡；索引（SQLite）只是可重建的加速結構。
/// 不認識任何檔案類型：類型相關的行為交給 DocumentKind，編輯器狀態交給各外掛的 EditorController。
@MainActor @Observable
final class VaultStore: DocumentSession {
    let fs: VaultFS
    @ObservationIgnored let plugins: PluginRegistry
    private(set) var tree: [VaultNode] = []
    /// 目前位置；`navigate` 會記入上一頁 / 下一頁的歷史
    private(set) var route: Route = .all {
        didSet {
            guard route != oldValue else { return }
            refreshBacklinks()
            // 離開開啟中的檔案：之前延後的 ContentFixer 現在可以處理
            if let old = oldValue.filePath, old != route.filePath, pendingFixes.contains(old) { scheduleFixes([]) }
        }
    }
    private(set) var backStack: [Route] = []
    private(set) var forwardStack: [Route] = []
    /// 開啟中的檔案；設為 nil 時回到它所在的資料夾（不記入歷史）
    var selection: String? {
        get { route.filePath }
        set {
            if let newValue { navigate(.file(newValue)) }
            else if route.filePath != nil { replace(with: currentFolder.isEmpty ? .all : .folder(currentFolder)) }
        }
    }
    /// 索引中的所有檔案，最近修改的在前（列表頁、側邊欄計數）
    private(set) var files: [IndexedFile] = []
    var searchText = "" {
        didSet { runSearch() }
    }
    private(set) var searchResults: [SearchHit] = []
    private(set) var backlinks: [SearchHit] = []
    private(set) var tags: [TagCount] = []
    private(set) var lastError: String?

    @ObservationIgnored private let index: VaultIndex?
    @ObservationIgnored private let previews: PreviewCache
    @ObservationIgnored private let writer: VaultWriter
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var derivedTask: Task<Void, Never>?
    /// 最近一次由 App 寫入的內容，用來分辨外部修改與自己的寫入
    @ObservationIgnored private var lastWritten: [String: Data] = [:]
    @ObservationIgnored private var watcher: VaultWatcher?
    /// 等待外掛 ContentFixer 處理的檔案（本機的變動）；開啟中的檔案留到離開後
    @ObservationIgnored private var pendingFixes = Set<String>()
    @ObservationIgnored private var fixTask: Task<Void, Never>?

    /// 本地內容有變動（App 內編輯或外部工具）：同步層據此排程上傳
    @ObservationIgnored var onLocalChange: (() -> Void)?
    /// App 內改名或搬移：同步層直接更新路徑，保留 file id
    @ObservationIgnored var onMove: ((_ from: String, _ to: String) -> Void)?

    init(plugins: PluginRegistry, kinds: KindRegistry, root: URL = VaultStore.defaultRoot()) {
        self.plugins = plugins
        fs = VaultFS(root: root, kinds: kinds)
        writer = VaultWriter(fs: fs)
        index = try? VaultIndex(fs: fs, contributors: plugins.indexContributors)
        previews = PreviewCache(directory: root.appending(path: "\(VaultFS.metaFolder)/cache/preview", directoryHint: .isDirectory))
        seedIfNeeded()
        writeVaultGuideIfNeeded()
        refresh()
        Task {
            // App 關閉期間的外部修改（例如 Claude Code）也交給 ContentFixer
            scheduleFixes(await syncIndex())
            scheduleDerivedRefresh()
        }
        #if DEBUG
        // UI 測試用：xcrun simctl launch … -EasyNotesOpen <path> -EasyNotesSearch <query>
        if let open = UserDefaults.standard.string(forKey: "EasyNotesOpen") { route = .file(open) }
        if let query = UserDefaults.standard.string(forKey: "EasyNotesSearch") { searchText = query }
        #endif
        watcher = VaultWatcher(root: root) { [weak self] paths in
            Task { await self?.scanLocalChanges(paths: paths) }
        }
        for controller in plugins.controllers { controller.attach(self) }
    }

    private var editors: [any EditorController] { plugins.controllers }

    /// 讓編輯器把尚未回報的變更寫回；改名、刪除、進入背景前呼叫
    func flushEditors() async {
        for editor in editors { await editor.flush() }
    }

    /// macOS：~/Documents/EasyNotes（Finder 與其他編輯器可直接開啟）
    /// iOS：App 的 Documents，透過「檔案」App 可見
    static func defaultRoot() -> URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/EasyNotes")
        #else
        URL.documentsDirectory.appending(path: "EasyNotes")
        #endif
    }

    func refresh() {
        do { tree = try fs.scan() } catch { report(error) }
    }

    // MARK: 導覽

    func navigate(_ target: Route) {
        guard target != route else { return }
        backStack.append(route)
        forwardStack.removeAll()
        route = target
    }

    /// 換掉目前位置但不記入歷史（iPhone 的導覽堆疊、刪除後回到資料夾）
    func replace(with target: Route) {
        route = target
    }

    func goBack() {
        while let previous = backStack.popLast() {
            guard exists(previous) else { continue }
            forwardStack.append(route)
            route = previous
            return
        }
    }

    func goForward() {
        while let next = forwardStack.popLast() {
            guard exists(next) else { continue }
            backStack.append(route)
            route = next
            return
        }
    }

    private func exists(_ route: Route) -> Bool {
        switch route {
        case .file(let path), .folder(let path):
            FileManager.default.fileExists(atPath: fs.url(for: path).path(percentEncoded: false))
        default: true
        }
    }

    /// 改名、搬移後，目前位置與歷史中指向舊路徑的項目一併更新
    private func routesMoved(from: String, to: String) {
        route = route.moved(from: from, to: to)
        backStack = backStack.map { $0.moved(from: from, to: to) }
        forwardStack = forwardStack.map { $0.moved(from: from, to: to) }
    }

    /// 刪除後，目前位置若在被刪的路徑下，回到上一層
    private func routesDeleted(_ path: String) {
        guard route.points(into: path) else { return }
        let parent = (path as NSString).deletingLastPathComponent
        route = parent.isEmpty ? .all : .folder(parent)
    }

    // MARK: 讀寫

    func readText(_ path: String) -> String {
        String(decoding: readData(path), as: UTF8.self)
    }

    func readData(_ path: String) -> Data {
        (try? fs.read(path)) ?? Data()
    }

    /// 寫入在背景的序列 actor 進行，不擋主執行緒且保持順序；寫完立即更新該檔索引
    func write(_ data: Data, to path: String) {
        lastWritten[path] = data
        Task { [writer, index] in
            do {
                try await writer.write(data, to: path)
                try await index?.update(path, data: data)
                scheduleDerivedRefresh()
                scheduleFixes([path])
                onLocalChange?()
            } catch {
                report(error)
            }
        }
    }

    // MARK: 外部修改

    /// 本機的外部修改（Finder、Claude Code、「檔案」App）：更新索引並交給外掛的 ContentFixer。
    /// macOS 由 FSEvents 觸發，只重掃事件帶來的 `paths`；iOS 在回到前景時完整比對（`paths` 為 nil）。
    func scanLocalChanges(paths: Set<String>? = nil) async {
        let changed = await syncIndex(paths: paths)
        scheduleFixes(changed)
        onLocalChange?()
    }

    /// 比對磁碟與索引：新增、修改、刪除的檔案會更新索引、檔案樹，並推送到開啟中的編輯器。回傳有變動的路徑
    @discardableResult
    func syncIndex(paths: Set<String>? = nil) async -> Set<String> {
        guard let index else { return [] }
        do {
            let changed = if let paths { try await index.sync(paths: paths) } else { try await index.sync() }
            guard !changed.isEmpty else { return [] }
            refresh()
            if let current = selection, changed.contains(current) {
                if FileManager.default.fileExists(atPath: fs.url(for: current).path(percentEncoded: false)) {
                    let data = readData(current)
                    if data != lastWritten[current] {
                        lastWritten[current] = data
                        for editor in editors { editor.externalChange(path: current, data: data) }
                    }
                } else {
                    routesDeleted(current)
                }
            }
            scheduleDerivedRefresh()
            return changed
        } catch {
            report(error)
            return []
        }
    }

    // MARK: 外掛的背景改寫（ContentFixer）

    /// 只處理本機產生的變動（App 內編輯、外部工具），不處理同步拉下來的內容。
    /// 連續變動合併後才執行：Claude Code 搬移內容時，兩個檔案都寫完再判斷。
    private func scheduleFixes(_ paths: Set<String>) {
        guard !plugins.contentFixers.isEmpty else { return }
        pendingFixes.formUnion(paths.filter { fs.kinds.kind(for: $0) != nil })
        guard !pendingFixes.isEmpty else { return }
        fixTask?.cancel()
        fixTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await runFixes()
        }
    }

    /// 開啟中的檔案不改寫（不在打字、注音組字中插入文字），留在佇列等離開後再處理
    private func runFixes() async {
        guard let index else { return }
        let paths = pendingFixes.filter { $0 != selection }
        pendingFixes.subtract(paths)
        var wrote = false
        for path in paths.sorted() {
            guard let kind = fs.kinds.kind(for: path), let original = try? fs.read(path) else { continue }
            var data = original
            for fixer in plugins.contentFixers {
                if let fixed = await fixer.fix(path: path, kindID: kind.id, data: data, index: index) { data = fixed }
            }
            guard data != original else { continue }
            // 處理期間被打開了：留到離開後
            guard path != selection else {
                pendingFixes.insert(path)
                continue
            }
            do {
                lastWritten[path] = data
                try fs.write(data, to: path)
                for editor in editors { editor.close(path: path) }
                try await index.update(path, data: data)
                wrote = true
            } catch { report(error) }
        }
        if wrote {
            scheduleDerivedRefresh()
            onLocalChange?()
        }
    }

    // MARK: 檔案操作

    /// 新檔案放在目前所在的資料夾（或開啟中檔案所在的資料夾）；其他頁面放在 Vault 根目錄
    var currentFolder: String {
        switch route {
        case .folder(let path): path
        case .file(let path): (path as NSString).deletingLastPathComponent
        default: ""
        }
    }

    func create(_ kind: any DocumentKind.Type, title: String) {
        do {
            let path = try fs.create(kind: kind, title: title, in: currentFolder)
            refresh()
            selection = path
            Task {
                await syncIndex(paths: [path])
                onLocalChange?()
            }
        } catch { report(error) }
    }

    func createFolder() {
        do {
            let path = try fs.createFolder(named: uniqueFolderName(in: currentFolder), in: currentFolder)
            refresh()
            navigate(.folder(path))
        } catch { report(error) }
    }

    /// 新增第一層資料夾（側邊欄 Spaces 的 +）
    func createSpace() {
        do {
            let path = try fs.createFolder(named: uniqueFolderName(in: ""), in: "")
            refresh()
            navigate(.folder(path))
        } catch { report(error) }
    }

    /// 把 Vault 外的檔案（匯入 PDF、CSV…）複製進 `folder`（預設為目前所在的資料夾）；`open` 時匯入後開啟
    func importFile(_ url: URL, into folder: String? = nil, open: Bool = true) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let path = try fs.importFile(from: url, in: folder ?? currentFolder)
            refresh()
            await syncIndex(paths: [path])
            if open { navigate(.file(path)) }
            onLocalChange?()
        } catch { report(error) }
    }

    /// 拖入列表頁的檔案：只接受已註冊的類型，匯入後留在原頁面
    func importDropped(_ urls: [URL], into folder: String) async -> Bool {
        let accepted = urls.filter { fs.kinds.kind(for: $0) != nil }
        for url in accepted { await importFile(url, into: folder, open: false) }
        return !accepted.isEmpty
    }

    /// 釘選寫在檔案內（Markdown 為 frontmatter），由 DocumentKind 決定格式。
    /// 寫入後還原 mtime：釘選不算編輯，不應讓文件跑到「最近」最上面。
    func setPinned(_ path: String, _ pinned: Bool) async {
        guard let kind = fs.kinds.kind(for: path) else { return }
        await flushEditors()
        let url = fs.url(for: path)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let data = kind.setPinned(pinned, in: readData(path)) else { return }
        do {
            lastWritten[path] = data
            try fs.write(data, to: path)
            if let mtime { try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path(percentEncoded: false)) }
            if path == selection { for editor in editors { editor.externalChange(path: path, data: data) } }
            await syncIndex(paths: [path])
            onLocalChange?()
        } catch { report(error) }
    }

    /// 改名後，把其他筆記中的 `[[舊名]]` 一併更新（保留別名）
    func rename(_ path: String, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await flushEditors()
        let ext = (path as NSString).pathExtension
        let name = isFolder(path) || ext.isEmpty || trimmed.hasSuffix("." + ext) ? trimmed : "\(trimmed).\(ext)"
        let oldTitle = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let newTitle = (name as NSString).deletingPathExtension
        do {
            let sources = isFolder(path) ? [] : (try await index?.sources(linkingTo: oldTitle) ?? [])
            let newPath = try fs.rename(path, to: name)
            onMove?(path, newPath)
            for editor in editors { editor.close(path: path) }
            refresh()
            routesMoved(from: path, to: newPath)

            for source in sources {
                let src = source == path ? newPath : source
                guard let kind = fs.kinds.kind(for: src),
                      let data = kind.renameLinks(in: readData(src), from: oldTitle, to: newTitle) else { continue }
                lastWritten[src] = data
                try fs.write(data, to: src)
                for editor in editors {
                    if src == selection { editor.externalChange(path: src, data: data) }
                    else { editor.close(path: src) }
                }
            }
            await syncIndex()
            onLocalChange?()
        } catch { report(error) }
    }

    func delete(_ path: String) async {
        await flushEditors()
        do {
            try fs.trash(path)
            for editor in editors { editor.close(path: path) }
            routesDeleted(path)
            refresh()
            await syncIndex()
            onLocalChange?()
        } catch { report(error) }
    }

    // MARK: 同步

    /// 同步要改寫、搬移或刪除檔案前：讓編輯器把未存的變更寫回，同步層才能讀到最新內容再合併
    func prepareForSync(_ path: String) async {
        await flushEditors()
    }

    /// 同步改寫、搬移或刪除了本地檔案：更新檔案樹、索引與編輯器
    func applySyncChange(path: String, oldPath: String?, data: Data?) async {
        refresh()
        if let oldPath {
            for editor in editors { editor.close(path: oldPath) }
            routesMoved(from: oldPath, to: path)
        }
        if let data {
            lastWritten[path] = data
            for editor in editors {
                if path == selection { editor.externalChange(path: path, data: data) } else { editor.close(path: path) }
            }
        } else if oldPath == nil {
            for editor in editors { editor.close(path: path) }
            routesDeleted(path)
        }
        await syncIndex(paths: Set([path] + (oldPath.map { [$0] } ?? [])))
    }

    /// [[連結]]：找到就開啟，找不到就在目前資料夾建立預設類型（第一個註冊的外掛）
    func openLink(_ target: String) {
        do {
            if let path = try fs.resolveLink(target) {
                selection = path
            } else if let kind = plugins.defaultKind {
                create(kind, title: target)
            }
        } catch { report(error) }
    }

    func search(_ query: String) {
        searchText = query
    }

    func modified(_ path: String) -> Date? {
        file(at: path)?.mtime
            ?? (try? fs.url(for: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// 附件（封面、插入的圖片）一律放 Vault 根目錄的這個資料夾
    static let attachmentsFolder = "附件"

    func importAttachment(_ url: URL) async -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let root = fs.root.standardizedFileURL.path(percentEncoded: false)
        let source = url.standardizedFileURL.path(percentEncoded: false)
        if source.hasPrefix(root) { return fs.path(for: url) }
        do {
            let path = try fs.importFile(from: url, in: Self.attachmentsFolder)
            onLocalChange?()
            return path
        } catch {
            report(error)
            return nil
        }
    }

    var resourceReader: @Sendable (String) async -> Data? {
        let fs = fs
        return { path in try? fs.read(path) }
    }

    func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fs.url(for: path).path(percentEncoded: false), isDirectory: &isDir)
            && isDir.boolValue
    }

    private func uniqueFolderName(in folder: String) -> String {
        var name = "新資料夾"
        var n = 2
        while FileManager.default.fileExists(atPath: fs.url(for: folder.isEmpty ? name : "\(folder)/\(name)").path(percentEncoded: false)) {
            name = "新資料夾 \(n)"
            n += 1
        }
        return name
    }

    // MARK: 搜尋、反向連結、標籤

    private func runSearch() {
        searchTask?.cancel()
        let query = searchText
        searchTask = Task { [index] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = (try? await index?.search(query)) ?? []
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    private func refreshBacklinks() {
        guard let path = selection, !isFolder(path) else {
            backlinks = []
            return
        }
        Task { [index] in
            let links = (try? await index?.backlinks(to: path)) ?? []
            if selection == path { backlinks = links }
        }
    }

    /// 索引變動後更新標籤、反向連結、自動完成清單；合併短時間內的多次變動
    private func scheduleDerivedRefresh() {
        derivedTask?.cancel()
        derivedTask = Task { [index] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let index else { return }
            tags = (try? await index.tags()) ?? []
            files = (try? await index.files()) ?? []
            let targets = linkTargets()
            for editor in editors { editor.linkTargetsChanged(targets) }
            refreshBacklinks()
            if !searchText.isEmpty { runSearch() }
        }
    }

    /// `[[` 自動完成與連結卡片：類型的圖示與顏色從 PluginRegistry 取，編輯器不認識其他外掛
    private func linkTargets() -> [LinkTarget] {
        files.map { file in
            let kindID = kindID(file.path)
            return LinkTarget(name: fs.kinds.displayName(file.path), path: file.path, symbol: plugins.symbol(for: kindID),
                              tint: plugins.tint(for: kindID), summary: file.summary, modified: file.mtime)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: 列表

    /// `folder` 之下（含子資料夾）的檔案數
    func fileCount(in folder: String) -> Int {
        files.count { $0.path.hasPrefix(folder + "/") }
    }

    func file(at path: String) -> IndexedFile? {
        files.first { $0.path == path }
    }

    /// 列表卡片的縮圖資料：依內容 hash 快取，在背景產生；外掛沒有註冊預覽時回傳 nil
    func preview(for file: IndexedFile) async -> DocumentPreview? {
        guard let kindID = kindID(file.path), let provider = plugins.preview(for: kindID) else { return nil }
        let fs = fs
        let path = file.path
        return await previews.preview(kindID: kindID, hash: file.hash, provider: provider) { try fs.read(path) }
    }

    func files(taggedWith tag: String) async -> [IndexedFile] {
        (try? await index?.files(taggedWith: tag)) ?? []
    }

    /// 顯示名稱：去掉已註冊的副檔名
    func displayName(_ path: String) -> String {
        fs.kinds.displayName(path)
    }

    func kindID(_ path: String) -> String? {
        fs.kinds.kind(for: path)?.id
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        print("[vault] \(error)")
    }

    // MARK: Vault 的 CLAUDE.md

    /// Vault 根目錄沒有 `CLAUDE.md` 時，以各外掛的段落建立；已存在就不改寫（使用者可以自行編輯）
    private func writeVaultGuideIfNeeded() {
        let path = "CLAUDE.md"
        guard !plugins.vaultGuides.isEmpty,
              !FileManager.default.fileExists(atPath: fs.url(for: path).path(percentEncoded: false)) else { return }
        let header = """
            # EasyNotes Vault

            這個資料夾是 EasyNotes 的 Vault。每筆筆記都是真實的檔案，App 的資料庫只是可重建的索引：直接讀寫這裡的檔案即可，App 會即時偵測、重新索引並同步到其他裝置。

            - 第一層資料夾是 App 側邊欄的「空間」；子資料夾可以任意建立。
            - 改名、搬移檔案都可以直接做，App 會以內容推斷並保留同步歷史。
            - 不要修改 `.easynotes/`（索引快取、同步狀態、複習紀錄與設定）。
            """
        let text = ([header] + plugins.vaultGuides).joined(separator: "\n\n") + "\n"
        do { try fs.write(Data(text.utf8), to: path) } catch { report(error) }
    }

    // MARK: 首次啟動的範例內容

    private func seedIfNeeded() {
        let marker = fs.url(for: "\(VaultFS.metaFolder)/seeded")
        guard !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) else { return }
        for (path, content) in Seed.files {
            try? fs.write(Data(content.utf8), to: path)
        }
        for (path, title) in Seed.templates {
            if let kind = fs.kinds.kind(for: path) { try? fs.write(kind.template(title: title), to: path) }
        }
        try? fs.write(Data(), to: "\(VaultFS.metaFolder)/seeded")
    }
}

private actor VaultWriter {
    let fs: VaultFS
    init(fs: VaultFS) { self.fs = fs }
    func write(_ data: Data, to path: String) throws {
        try fs.write(data, to: path)
    }
}
