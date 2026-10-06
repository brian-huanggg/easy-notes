import EasyNotesCore
import EasyNotesUI
import Foundation
import Observation

/// App-level vault state: file tree, selection, search, backlinks, tags.
/// All content lives in files; the index (SQLite) is only a rebuildable acceleration structure.
/// Knows no file types: type-specific behavior goes to DocumentKind and editor state to each plugin's EditorController.
@MainActor @Observable
final class VaultStore: DocumentSession {
    private static let log = DiagnosticsLog.logger("vault")
    let fs: VaultFS
    @ObservationIgnored let plugins: PluginRegistry
    private(set) var tree: [VaultNode] = []
    /// Current location; `navigate` records it in the back / forward history
    private(set) var route: Route = .all {
        didSet {
            guard route != oldValue else { return }
            tabs.active.route = route
            // A side panel belongs to the whiteboard that opened it: it closes when navigating elsewhere
            if sidePath != nil, route.filePath != oldValue.filePath { sidePath = nil }
            refreshBacklinks()
            // Leaving an open file: the previously deferred ContentFixer can handle it now
            if let old = oldValue.filePath, old != route.filePath, pendingFixes.contains(old) { scheduleFixes([]) }
        }
    }
    /// The file open in the side panel next to the main content (a whiteboard's note card); supported only by the Mac / iPad shell
    var sidePath: String?
    @ObservationIgnored var supportsSide = false
    private(set) var backStack: [Route] = [] { didSet { tabs.active.back = backStack } }
    private(set) var forwardStack: [Route] = [] { didSet { tabs.active.forward = forwardStack } }
    /// Tabs (Mac / iPad): background tabs store only location and history and hold no editor; the current tab's content stays in sync with `route` and the history above
    private(set) var tabs = TabSet(TabState(route: .all)) { didSet { saveTabs() } }
    var supportsTabs = false
    @ObservationIgnored private var tabsRestored = false
    /// The open file; setting it to nil returns to its containing folder (not recorded in history)
    var selection: String? {
        get { route.filePath }
        set {
            if let newValue { navigate(.file(newValue)) }
            else if route.filePath != nil { replace(with: currentFolder.isEmpty ? .all : .folder(currentFolder)) }
        }
    }
    /// All files in the index, most recently modified first (list pages, sidebar counts)
    private(set) var files: [IndexedFile] = []
    var searchText = "" {
        didSet { runSearch() }
    }
    private(set) var searchResults: [SearchHit] = []
    private(set) var backlinks: [SearchHit] = []
    private(set) var tags: [TagCount] = []
    private(set) var lastError: String?
    /// The vault's sample content was created in this launch (fresh install); the "What's New" window uses it to skip the first launch
    @ObservationIgnored private(set) var isFreshInstall = false

    @ObservationIgnored let index: VaultIndex?
    @ObservationIgnored private let previews: PreviewCache
    @ObservationIgnored private let writer: VaultWriter
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var derivedTask: Task<Void, Never>?
    /// Content the app last wrote (including what was read for an open file): used to tell external edits from its own writes,
    /// and the comparison base when saving (if the disk no longer matches this → an external tool just changed it, so merge before writing)
    @ObservationIgnored private var lastWritten: [String: Data] = [:]
    @ObservationIgnored private var watcher: VaultWatcher?
    /// Files waiting for a plugin's ContentFixer (local changes); open files wait until they are left
    @ObservationIgnored private var pendingFixes = Set<String>()
    @ObservationIgnored private var fixTask: Task<Void, Never>?

    /// Local content changed (in-app edit or external tool): the sync layer schedules an upload from it
    @ObservationIgnored var onLocalChange: (() -> Void)?
    /// In-app rename or move: the sync layer updates the path directly and keeps the file id
    @ObservationIgnored var onMove: ((_ from: String, _ to: String) -> Void)?
    /// "Delete Immediately": the sync layer marks the file (and companions, or everything in a folder) for a permanent remote delete.
    /// Called before the files are removed, because a scan that sees a vanished file would otherwise record an ordinary, restorable delete
    @ObservationIgnored var onPurge: ((_ path: String) async throws -> Void)?

    init(plugins: PluginRegistry, kinds: KindRegistry, root: URL = VaultStore.defaultRoot()) {
        self.plugins = plugins
        fs = VaultFS(root: root, kinds: kinds)
        writer = VaultWriter(fs: fs)
        index = try? VaultIndex(fs: fs, contributors: plugins.indexContributors,
                           language: Bundle.main.preferredLocalizations.first ?? "")
        previews = PreviewCache(directory: root.appending(path: "\(VaultFS.metaFolder)/cache/preview", directoryHint: .isDirectory))
        seedIfNeeded()
        writeVaultGuideIfNeeded()
        refresh()
        Task {
            // External edits made while the app was closed (for example by Claude Code) also go to ContentFixer
            scheduleFixes(await syncIndex())
            scheduleDerivedRefresh()
        }
        #if DEBUG
        // For UI tests: xcrun simctl launch … -EasyNotesOpen <path> -EasyNotesSearch <query>
        if let open = UserDefaults.standard.string(forKey: LaunchKey.open) { route = .file(open) }
        if let query = UserDefaults.standard.string(forKey: "EasyNotesSearch") { searchText = query }
        #endif
        watcher = VaultWatcher(root: root) { [weak self] paths in
            Task { await self?.scanLocalChanges(paths: paths) }
        }
        for controller in plugins.controllers { controller.attach(self) }
    }

    private var editors: [any EditorController] { plugins.controllers }
    @ObservationIgnored private var hasLaunched = false

    /// The first window appeared: editors may now create platform views (see `EditorController.launched`)
    func windowAppeared() {
        guard !hasLaunched else { return }
        hasLaunched = true
        for editor in editors { editor.launched() }
    }

    /// Makes editors write back changes not yet reported; called before rename, delete and going to the background
    func flushEditors() async {
        for editor in editors { await editor.flush() }
    }

    /// macOS: ~/Documents/EasyNotes (Finder and other editors can open it directly)
    /// iOS: the app's Documents, visible through the Files app
    static func defaultRoot() -> URL {
        if let root = TestHooks.vaultRoot { return root } // E2E: one temporary vault per test
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/EasyNotes")
        #else
        return URL.documentsDirectory.appending(path: "EasyNotes")
        #endif
    }

    func refresh() {
        do { tree = try fs.scan() } catch { report(error) }
    }

    // MARK: Navigation

    func navigate(_ target: Route) {
        guard target != route else { return }
        // With tabs, opening a file always uses a new tab (switching if already open); folders, lists and other locations stay in the current tab
        if supportsTabs, case .file = target { return openInTab(target) }
        backStack.append(route)
        forwardStack.removeAll()
        route = target
    }

    // MARK: Tabs

    /// A tab's state: location plus its own back / forward
    struct TabState {
        var route: Route
        var back: [Route] = []
        var forward: [Route] = []
    }

    /// A tab's location; the current tab follows `route`
    func tabRoute(_ tab: TabSet<TabState>.Tab) -> Route {
        tab.id == tabs.activeID ? route : tab.state.route
    }

    private func load(_ state: TabState) {
        route = state.route
        backStack = state.back
        forwardStack = state.forward
    }

    private func openInTab(_ target: Route) {
        if let existing = tabs.firstTab(where: { $0.route == target }) { return activateTab(existing.id) }
        tabs.open(TabState(route: target))
        load(tabs.active)
    }

    func newTab() {
        tabs.open(TabState(route: .all))
        load(tabs.active)
    }

    func activateTab(_ id: UUID) {
        guard id != tabs.activeID else { return }
        tabs.activate(id)
        load(tabs.active)
    }

    func cycleTab(_ offset: Int) {
        tabs.activate(offset: offset)
        load(tabs.active)
    }

    func closeTab(_ id: UUID) {
        guard let closing = tabs.tabs.first(where: { $0.id == id }) else { return }
        let path = tabRoute(closing).filePath
        tabs.close(id, blank: TabState(route: .all))
        load(tabs.active)
        // A file no longer open: the editor drops the state it kept (rebuilt from disk content when reopened)
        if let path, path != selection, path != sidePath {
            for editor in editors { editor.close(path: path) }
        }
    }

    func closeOtherTabs(keeping id: UUID) {
        let others = tabs.tabs.filter { $0.id != id }.map(\.id)
        for other in others { closeTab(other) }
        activateTab(id)
    }

    private static let tabsKey = "EasyNotesOpenTabs"

    private func saveTabs() {
        guard supportsTabs, tabsRestored else { return }
        let routes = tabs.tabs.map(tabRoute)
        let saved = SavedTabs(routes: routes, active: tabs.activeIndex)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.tabsKey) }
    }

    /// Called when the shell supports tabs (SplitShell on Mac / iPad); on first enable restores the tabs left open last time (per device, not synced)
    func enableTabs() {
        supportsTabs = true
        guard !tabsRestored else { return }
        tabsRestored = true
        #if DEBUG
        // E2E and explicitly opened files: start from a clean state
        if TestHooks.vaultRoot != nil || UserDefaults.standard.string(forKey: LaunchKey.open) != nil { return }
        #endif
        guard let data = UserDefaults.standard.data(forKey: Self.tabsKey),
              let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) else { return }
        let routes = saved.routes.filter(exists)
        guard !routes.isEmpty else { return }
        let active = saved.routes.prefix(saved.active).filter(exists).count
        tabs = TabSet(restoring: routes.map { TabState(route: $0) }, active: active, fallback: TabState(route: .all))
        load(tabs.active)
    }

    private struct SavedTabs: Codable {
        var routes: [Route]
        var active: Int
    }

    /// Replaces the current location without recording history (iPhone's navigation stack, returning to the folder after delete)
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

    /// After rename or move, the current location and history entries pointing at the old path are updated together
    private func routesMoved(from: String, to: String) {
        if let side = sidePath, case .file(let moved) = Route.file(side).moved(from: from, to: to) { sidePath = moved }
        tabs.update { state in
            state.route = state.route.moved(from: from, to: to)
            state.back = state.back.map { $0.moved(from: from, to: to) }
            state.forward = state.forward.map { $0.moved(from: from, to: to) }
        }
        load(tabs.active)
    }

    /// After delete, if the current location is under the deleted path, go back one level
    private func routesDeleted(_ path: String) {
        if let side = sidePath, Route.file(side).points(into: path) { sidePath = nil }
        // A background tab points at a deleted file or folder: just close it
        for tab in tabs.tabs where tab.id != tabs.activeID && tab.state.route.points(into: path) {
            tabs.close(tab.id, blank: TabState(route: .all))
        }
        guard route.points(into: path) else { return }
        let parent = (path as NSString).deletingLastPathComponent
        route = parent.isEmpty ? .all : .folder(parent)
    }

    // MARK: Read / write

    func readText(_ path: String) -> String {
        String(decoding: readData(path), as: UTF8.self)
    }

    func readData(_ path: String) -> Data {
        let data = (try? fs.read(path)) ?? Data()
        // Content read when the editor opened the file: used at save time to tell whether an external tool changed it first
        if isOpen(path) { lastWritten[path] = data }
        return data
    }

    /// Writes run on a background serial actor, so the main thread is not blocked and order is kept; the file's index is updated right after writing.
    /// When an external tool just changed the file before saving and file watching has not notified yet, the merged result is written and pushed back to the editor without overwriting the external change
    func write(_ data: Data, to path: String) {
        guard VaultFS.isSafe(path: path) else { return } // A path from external input such as the Bridge is never written outside the vault
        let expected = lastWritten[path]
        lastWritten[path] = data
        let device = SyncCoordinator.deviceName
        Task { [writer, index] in
            do {
                let result = try await writer.write(data, to: path, expecting: expected, deviceName: device)
                // When another save arrives later it is handed to this (it compares with the disk once more)
                if result.data != data, lastWritten[path] == data {
                    lastWritten[path] = result.data
                    if isOpen(path) { for editor in editors { editor.externalChange(path: path, data: result.data) } }
                }
                if let copy = result.conflictCopy {
                    refresh()
                    try await index?.update(copy, data: data)
                }
                try await index?.update(path, data: result.data)
                scheduleDerivedRefresh()
                for editor in editors { editor.vaultChanged([path]) }
                scheduleFixes([path])
                onLocalChange?()
            } catch {
                report(error)
            }
        }
    }

    // MARK: External changes

    /// Local external changes (Finder, Claude Code, the Files app): updates the index and hands them to plugins' ContentFixer.
    /// On macOS FSEvents triggers it and only the event's `paths` are rescanned; on iOS a full comparison runs when returning to the foreground (`paths` is nil).
    func scanLocalChanges(paths: Set<String>? = nil) async {
        let changed = await syncIndex(paths: paths)
        scheduleFixes(changed)
        onLocalChange?()
    }

    /// Compares disk with the index: added, modified and deleted files update the index and file tree and are pushed to open editors. Returns the changed paths
    @discardableResult
    func syncIndex(paths: Set<String>? = nil) async -> Set<String> {
        guard let index else { return [] }
        do {
            let changed = if let paths { try await index.sync(paths: paths) } else { try await index.sync() }
            guard !changed.isEmpty else { return [] }
            refresh()
            if let current = selection, changed.contains(current) {
                if FileManager.default.fileExists(atPath: fs.url(for: current).path(percentEncoded: false)) {
                    pushExternalChange(current)
                } else {
                    routesDeleted(current)
                }
            }
            // A companion of an open file (for example a PDF's annotation sidecar) was changed externally: hand it to the same editor to merge
            if let current = selection {
                for companion in changed where fs.kinds.mainFile(ofCompanion: companion) == current && fs.exists(companion) {
                    pushExternalChange(companion)
                }
            }
            scheduleDerivedRefresh()
            for editor in editors { editor.vaultChanged(changed) }
            return changed
        } catch {
            report(error)
            return []
        }
    }

    private func pushExternalChange(_ path: String) {
        let data = (try? fs.read(path)) ?? Data()
        guard data != lastWritten[path] else { return }
        lastWritten[path] = data
        for editor in editors { editor.externalChange(path: path, data: data) }
    }

    /// An open file or its companion
    private func isOpen(_ path: String) -> Bool {
        let main = fs.kinds.mainFile(ofCompanion: path) ?? path
        return main == selection || main == sidePath
    }

    // MARK: Background rewrites by plugins (ContentFixer)

    /// Handles only locally produced changes (in-app edits, external tools), never content pulled by sync.
    /// Runs after consecutive changes are coalesced: when Claude Code moves content, decide after both files are written.
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

    /// Open files are not rewritten (no text inserted during typing or Zhuyin composition); they stay in the queue until left
    private func runFixes() async {
        guard let index else { return }
        let paths = pendingFixes.filter { $0 != selection }
        pendingFixes.subtract(paths)
        var wrote = Set<String>()
        for path in paths.sorted() {
            guard let kind = fs.kinds.kind(for: path), let original = try? fs.read(path) else { continue }
            var data = original
            for fixer in plugins.contentFixers {
                if let fixed = await fixer.fix(path: path, kindID: kind.id, data: data, index: index) { data = fixed }
            }
            guard data != original else { continue }
            // Opened during processing: leave it until it is left
            guard path != selection else {
                pendingFixes.insert(path)
                continue
            }
            do {
                lastWritten[path] = data
                try fs.write(data, to: path)
                for editor in editors { editor.close(path: path) }
                try await index.update(path, data: data)
                wrote.insert(path)
            } catch { report(error) }
        }
        if !wrote.isEmpty {
            scheduleDerivedRefresh()
            for editor in editors { editor.vaultChanged(wrote) }
            onLocalChange?()
        }
    }

    // MARK: File operations

    /// A new file goes in the current folder (or the folder of the open file); other pages use the vault root
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

    /// Adds a first-level folder (the + of the sidebar Spaces)
    func createSpace() {
        do {
            let path = try fs.createFolder(named: uniqueFolderName(in: ""), in: "")
            refresh()
            navigate(.folder(path))
        } catch { report(error) }
    }

    /// Copies files from outside the vault (import PDF, CSV…) into `folder` (default: the current folder); with `open`, opens it after import
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

    /// Files dropped onto a list page: only registered types are accepted, and the user stays on the page after import
    func importDropped(_ urls: [URL], into folder: String) async -> Bool {
        let accepted = urls.filter { fs.kinds.kind(for: $0) != nil }
        for url in accepted { await importFile(url, into: folder, open: false) }
        return !accepted.isEmpty
    }

    /// Pinning is written inside the file (frontmatter for Markdown), with the format decided by DocumentKind.
    /// Restores mtime after writing: pinning is not an edit and must not push the document to the top of "Recents".
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

    /// After a rename, also updates `[[old name]]` in other notes (keeping aliases)
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
            let newPathGuess = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            let companions = isFolder(path) ? [] : fs.companionMoves(from: path, to: newPathGuess)
            let newPath = try fs.rename(path, to: name)
            didMove(from: path, to: newPath, companions: companions)

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

    /// Drag to another folder (`""` = root): the name is unchanged, so links need no rewriting
    func move(_ path: String, toFolder folder: String) async {
        guard fs.exists(path), folder.isEmpty || isFolder(folder),
              (path as NSString).deletingLastPathComponent != folder else { return }
        await flushEditors()
        do {
            let newPathGuess = folder.isEmpty ? (path as NSString).lastPathComponent
                                              : (folder as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            let companions = isFolder(path) ? [] : fs.companionMoves(from: path, to: newPathGuess)
            let newPath = try fs.move(path, toFolder: folder)
            didMove(from: path, to: newPath, companions: companions)
            await syncIndex()
            onLocalChange?()
        } catch { report(error) }
    }

    /// Companions move together through `fs.rename` / `fs.move`; the sync layer, editors and navigation must know too
    private func didMove(from path: String, to newPath: String, companions: [(from: String, to: String)]) {
        for move in [(from: path, to: newPath)] + companions where fs.exists(move.to) {
            onMove?(move.from, move.to)
            for editor in editors {
                editor.close(path: move.from)
                editor.moved(from: move.from, to: move.to)
            }
        }
        refresh()
        routesMoved(from: path, to: newPath)
    }

    func delete(_ path: String) async {
        await flushEditors()
        do {
            let companions = fs.companions(of: path)
            try fs.trash(path) // Companions are deleted together
            for closed in [path] + companions { for editor in editors { editor.close(path: closed) } }
            routesDeleted(path)
            refresh()
            await syncIndex()
            onLocalChange?()
        } catch { report(error) }
    }

    /// Delete for good: no system trash, no "Recently Deleted"; sync purges the file on every device. Companions (PDF ink, sheet display
    /// settings) go with their main file, and a folder takes everything inside it
    func deleteImmediately(_ path: String) async {
        await flushEditors()
        do {
            let companions = fs.companions(of: path)
            try await onPurge?(path)
            try fs.deleteImmediately(path)
            for closed in [path] + companions {
                lastWritten[closed] = nil
                for editor in editors { editor.close(path: closed) }
            }
            routesDeleted(path)
            refresh()
            await syncIndex()
            await prunePreviews()
            onLocalChange?()
        } catch { report(error) }
    }

    /// After a permanent delete (here or on another device): drops cached thumbnails of every file that is no longer in the vault
    func prunePreviews() async {
        guard let hashes = try? await index?.files().map(\.hash) else { return }
        await previews.prune(keeping: Set(hashes))
    }

    // MARK: Sync

    /// Before sync rewrites, moves or deletes a file: lets editors write back unsaved changes so the sync layer reads the latest content before merging
    func prepareForSync(_ path: String) async {
        await flushEditors()
    }

    /// Sync rewrote, moved or deleted a local file: updates the file tree, index and editors
    func applySyncChange(path: String, oldPath: String?, data: Data?) async {
        refresh()
        if let oldPath {
            for editor in editors { editor.close(path: oldPath) }
            routesMoved(from: oldPath, to: path)
        }
        if let data {
            lastWritten[path] = data
            for editor in editors {
                if isOpen(path) { editor.externalChange(path: path, data: data) } else { editor.close(path: path) }
            }
        } else if oldPath == nil {
            for editor in editors { editor.close(path: path) }
            routesDeleted(path)
        }
        let paths = Set([path] + (oldPath.map { [$0] } ?? []))
        await syncIndex(paths: paths)
        // Synced files under `.easynotes/` (for example review logs) do not enter the index; plugins are notified separately
        let meta = paths.filter { $0.hasPrefix(VaultFS.metaFolder + "/") }
        if !meta.isEmpty { for editor in editors { editor.vaultChanged(meta) } }
    }

    /// [[link]]: opens it if found, otherwise creates the default kind (the first registered plugin) in the current folder
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

    var vault: VaultFS { fs }

    func openBeside(_ path: String) {
        if supportsSide, path != selection { sidePath = path } else { open(path, line: nil) }
    }

    func open(_ path: String, line: Int?) {
        selection = path
        if let line { for editor in editors { editor.reveal(path: path, line: line) } }
    }

    func metaChanged() {
        onLocalChange?()
    }

    func fileMoved(from: String, to: String) {
        onMove?(from, to)
        Task {
            await syncIndex(paths: [from, to])
            onLocalChange?()
        }
    }

    func modified(_ path: String) -> Date? {
        file(at: path)?.mtime
            ?? (try? fs.url(for: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func importAttachment(_ url: URL) async -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let root = fs.root.standardizedFileURL.path(percentEncoded: false)
        let source = url.standardizedFileURL.path(percentEncoded: false)
        if source.hasPrefix(root) { return fs.path(for: url) }
        do {
            let path = try fs.importFile(from: url, in: Attachments.folder)
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

    /// `embed://`: the file preview image (cached by hash, generated in the background if missing)
    var embedImageReader: @Sendable (String) async -> Data? {
        { [weak self] path in
            guard let self, let file = await file(at: path) else { return nil }
            return await preview(for: file)?.image
        }
    }

    var previewReader: @Sendable (String) async -> DocumentPreview? {
        { [weak self] path in
            guard let self, let file = await file(at: path) else { return nil }
            return await preview(for: file)
        }
    }

    func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fs.url(for: path).path(percentEncoded: false), isDirectory: &isDir)
            && isDir.boolValue
    }

    private func uniqueFolderName(in folder: String) -> String {
        var name = L("新資料夾")
        var n = 2
        while FileManager.default.fileExists(atPath: fs.url(for: folder.isEmpty ? name : "\(folder)/\(name)").path(percentEncoded: false)) {
            name = L("新資料夾 \(n)")
            n += 1
        }
        return name
    }

    // MARK: Search, backlinks, tags

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

    /// After the index changes, updates tags, backlinks and the autocomplete list; coalesces several changes in a short time
    private func scheduleDerivedRefresh() {
        derivedTask?.cancel()
        derivedTask = Task { [index] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let index else { return }
            refresh() // After `write` creates a new file (Anki import, sync) FSEvents no longer reports a change, so the file tree is updated here
            tags = (try? await index.tags()) ?? []
            files = (try? await index.files()) ?? []
            let targets = linkTargets()
            for editor in editors { editor.linkTargetsChanged(targets) }
            refreshBacklinks()
            if !searchText.isEmpty { runSearch() }
        }
    }

    /// `[[` autocomplete and link cards: type icon and color come from PluginRegistry, so the editor knows no other plugin
    private func linkTargets() -> [LinkTarget] {
        files.map { file in
            let kindID = kindID(file.path)
            return LinkTarget(name: fs.kinds.displayName(file.path), path: file.path, symbol: plugins.symbol(for: kindID),
                              tint: plugins.tint(for: kindID), summary: file.summary, modified: file.mtime,
                              hash: file.hash)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Lists

    /// Number of files under `folder` (including subfolders)
    func fileCount(in folder: String) -> Int {
        files.count { $0.path.hasPrefix(folder + "/") }
    }

    func file(at path: String) -> IndexedFile? {
        files.first { $0.path == path }
    }

    /// Thumbnail data for list cards: cached by content hash and generated in the background; nil when no plugin registered a preview
    func preview(for file: IndexedFile) async -> DocumentPreview? {
        guard let kindID = kindID(file.path), let provider = plugins.preview(for: kindID) else { return nil }
        let fs = fs
        let path = file.path
        return await previews.preview(kindID: kindID, hash: file.hash, provider: provider) { try fs.read(path) }
    }

    func files(taggedWith tag: String) async -> [IndexedFile] {
        (try? await index?.files(taggedWith: tag)) ?? []
    }

    /// Display name: the registered extension removed
    func displayName(_ path: String) -> String {
        fs.kinds.displayName(path)
    }

    func kindID(_ path: String) -> String? {
        fs.kinds.kind(for: path)?.id
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        Self.log.error("vault operation failed: \(DiagnosticsLog.describe(error), privacy: .public)")
    }

    // MARK: The vault's CLAUDE.md

    /// When the vault root has no `CLAUDE.md`, creates it from the plugins' sections; an existing one is never rewritten (the user may edit it)
    private func writeVaultGuideIfNeeded() {
        let path = "CLAUDE.md"
        guard !plugins.vaultGuides.isEmpty,
              !FileManager.default.fileExists(atPath: fs.url(for: path).path(percentEncoded: false)) else { return }
        // l10n:fixed The vault's CLAUDE.md is read by Claude Code and is always English (see translation.md)
        let header = """
            # EasyNotes Vault

            This folder is an EasyNotes vault. Every note is a real file; the app's database is only a rebuildable index. Read and write the files here directly: the app detects changes immediately, re-indexes, and syncs them to other devices.

            - Top-level folders are the "spaces" in the app's sidebar; subfolders can be created freely.
            - Renaming and moving files is fine: the app infers the move from file content and keeps the sync history.
            - Do not modify `.easynotes/` (index cache, sync state, review logs and settings).
            """
        let text = ([header] + plugins.vaultGuides).joined(separator: "\n\n") + "\n"
        do { try fs.write(Data(text.utf8), to: path) } catch { report(error) }
    }

    // MARK: First-launch sample content

    private func seedIfNeeded() {
        let marker = fs.url(for: "\(VaultFS.metaFolder)/seeded")
        guard !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) else { return }
        isFreshInstall = true
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
    func write(_ data: Data, to path: String, expecting expected: Data?,
               deviceName: String) throws -> (data: Data, conflictCopy: String?) {
        try fs.write(data, to: path, expecting: expected, deviceName: deviceName)
    }
}
