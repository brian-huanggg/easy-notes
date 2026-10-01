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
    var selection: String? {
        didSet { if selection != oldValue { refreshBacklinks() } }
    }
    var searchText = "" {
        didSet { runSearch() }
    }
    private(set) var searchResults: [SearchHit] = []
    private(set) var backlinks: [SearchHit] = []
    private(set) var tags: [TagCount] = []
    private(set) var lastError: String?

    @ObservationIgnored private let index: VaultIndex?
    @ObservationIgnored private let writer: VaultWriter
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var derivedTask: Task<Void, Never>?
    /// 最近一次由 App 寫入的內容，用來分辨外部修改與自己的寫入
    @ObservationIgnored private var lastWritten: [String: Data] = [:]
    @ObservationIgnored private var watcher: VaultWatcher?

    init(plugins: PluginRegistry, kinds: KindRegistry, root: URL = VaultStore.defaultRoot()) {
        self.plugins = plugins
        fs = VaultFS(root: root, kinds: kinds)
        writer = VaultWriter(fs: fs)
        index = try? VaultIndex(fs: fs)
        seedIfNeeded()
        refresh()
        selection = tree.first { !$0.isFolder }?.path
        Task { await syncIndex() }
        #if DEBUG
        // UI 測試用：xcrun simctl launch … -EasyNotesOpen <path> -EasyNotesSearch <query>
        if let open = UserDefaults.standard.string(forKey: "EasyNotesOpen") { selection = open }
        if let query = UserDefaults.standard.string(forKey: "EasyNotesSearch") { searchText = query }
        #endif
        watcher = VaultWatcher(root: root) { [weak self] in
            Task { await self?.syncIndex() }
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
            } catch {
                report(error)
            }
        }
    }

    // MARK: 外部修改

    /// 比對磁碟與索引：外部新增、修改、刪除的檔案會更新索引、檔案樹，並推送到開啟中的編輯器。
    /// macOS 由 FSEvents 觸發；iOS 在回到前景時觸發。
    func syncIndex() async {
        guard let index else { return }
        do {
            let changed = try await index.sync()
            guard !changed.isEmpty else { return }
            refresh()
            if let current = selection, changed.contains(current) {
                if FileManager.default.fileExists(atPath: fs.url(for: current).path(percentEncoded: false)) {
                    let data = readData(current)
                    if data != lastWritten[current] {
                        lastWritten[current] = data
                        for editor in editors { editor.externalChange(path: current, data: data) }
                    }
                } else {
                    selection = nil
                }
            }
            scheduleDerivedRefresh()
        } catch {
            report(error)
        }
    }

    // MARK: 檔案操作

    /// 新檔案放在目前選取的資料夾（或選取檔案所在的資料夾）
    var currentFolder: String {
        guard let selection else { return "" }
        if isFolder(selection) { return selection }
        return (selection as NSString).deletingLastPathComponent
    }

    func create(_ kind: any DocumentKind.Type, title: String) {
        do {
            let path = try fs.create(kind: kind, title: title, in: currentFolder)
            refresh()
            selection = path
            Task { await syncIndex() }
        } catch { report(error) }
    }

    func createFolder() {
        do {
            let path = try fs.createFolder(named: uniqueFolderName(), in: currentFolder)
            refresh()
            selection = path
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
            for editor in editors { editor.close(path: path) }
            refresh()
            if selection == path { selection = newPath }

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
        } catch { report(error) }
    }

    func delete(_ path: String) async {
        await flushEditors()
        do {
            try fs.trash(path)
            for editor in editors { editor.close(path: path) }
            if selection == path { selection = nil }
            refresh()
            await syncIndex()
        } catch { report(error) }
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

    func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fs.url(for: path).path(percentEncoded: false), isDirectory: &isDir)
            && isDir.boolValue
    }

    private func uniqueFolderName() -> String {
        var name = "新資料夾"
        var n = 2
        while FileManager.default.fileExists(atPath: fs.url(for: currentFolder.isEmpty ? name : "\(currentFolder)/\(name)").path(percentEncoded: false)) {
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
            let targets = (try? await index.linkTargets()) ?? []
            for editor in editors { editor.linkTargetsChanged(targets) }
            refreshBacklinks()
            if !searchText.isEmpty { runSearch() }
        }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        print("[vault] \(error)")
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
