import EasyNotesCore
import SwiftUI

/// The entry point of each plugin. Called in order at app launch; the plugin registers file types, editors and menus here.
public protocol EasyNotesPlugin {
    @MainActor static func register(in registry: PluginRegistry)
}

/// The plugin registry. Written only at launch; the part Core needs is turned into the UI-free KindRegistry by `makeKinds()`.
/// Extension points are added only when a plugin really needs them, never designed in advance.
@MainActor
public final class PluginRegistry {
    /// Registered file types and their appearance; filter chips, icons and type colors all come from here
    public struct KindInfo: Identifiable {
        public var id: String { kind.id }
        public let kind: any DocumentKind.Type
        /// The filter chip's name ("Notes", "Whiteboard")
        public let name: String
        public let symbol: String
        public let tint: KindTint
    }

    public struct NewFileCommand: Identifiable {
        public var id: String { title }
        public let title: String
        public let kind: any DocumentKind.Type
        public let symbol: String
        public let shortcut: KeyboardShortcut?
        /// The default name of a new file
        public let defaultName: String
    }

    /// Copies a file in from outside the vault (import PDF, CSV…); the selectable types = that Kind's extensions
    public struct ImportCommand: Identifiable {
        public var id: String { title }
        public let title: String
        public let kind: any DocumentKind.Type
        public let symbol: String
        public let shortcut: KeyboardShortcut?
    }

    /// Items plugins add to the sidebar (for example Flashcards' Review); the app hardcodes none
    public struct Panel: Identifiable {
        public let id: String
        public let title: String
        public let symbol: String
        /// The count on the right of the sidebar (for example cards due); nil = not shown. `tint` is the count's color
        public let badge: @MainActor () -> Int?
        public let badgeTint: ColorToken?
        public let content: @MainActor () -> AnyView
    }

    public struct MenuItem: Identifiable {
        public var id: String { title }
        public let title: String
        public let shortcut: KeyboardShortcut?
        public let action: @MainActor () -> Void

        public init(_ title: String, shortcut: KeyboardShortcut? = nil, action: @escaping @MainActor () -> Void) {
            self.title = title
            self.shortcut = shortcut
            self.action = action
        }
    }

    public struct Menu: Identifiable {
        public var id: String { title }
        public let title: String
        /// Sections are separated by dividers
        public let sections: [[MenuItem]]
    }

    /// In registration order
    public private(set) var kindInfos: [KindInfo] = []
    /// Companion types (`DocumentKind.companionOf`): enter KindRegistry and are indexed and synced as usual, but are not filter chips and have no icon
    public private(set) var companionKinds: [any DocumentKind.Type] = []
    private var previews: [String: any DocumentPreviewProvider] = [:]
    private var editors: [String: (String) -> AnyView] = [:]
    public private(set) var newFileCommands: [NewFileCommand] = []
    public private(set) var importCommands: [ImportCommand] = []
    public private(set) var panels: [Panel] = []
    public private(set) var controllers: [any EditorController] = []
    public private(set) var menus: [Menu] = []
    public private(set) var indexContributors: [any IndexContributor] = []
    public private(set) var contentFixers: [any ContentFixer] = []
    /// Sections of the vault root `CLAUDE.md` (Markdown), in registration order
    public private(set) var vaultGuides: [String] = []
    /// Subfolders under `.easynotes/` that take part in sync (handed to `SyncEngine`)
    public private(set) var syncedMetaFolders: [String] = []

    public init() {}

    // MARK: Registration

    /// The first registered Kind is the default type: a file of this type is created when a `[[link]]` target is not found.
    /// `name`: the filter chip's name; `tint`: the type color for icons, filter chips and thumbnail backgrounds, never hardcoded in the app
    public func addKind(_ kind: any DocumentKind.Type, name: String, symbol: String, tint: KindTint = .neutral) {
        kindInfos.append(KindInfo(kind: kind, name: name, symbol: symbol, tint: tint))
    }

    /// A companion type, for example a PDF's annotation sidecar `.pdf.ink`
    public func addCompanionKind(_ kind: any DocumentKind.Type) {
        companionKinds.append(kind)
    }

    /// The list card thumbnail; types without one show a skeleton placeholder
    public func addPreview(for kindID: String, _ provider: some DocumentPreviewProvider) {
        previews[kindID] = provider
    }

    /// The editor is created from a vault-relative path; called again on every file switch
    public func addEditor(for kindID: String, _ make: @escaping @MainActor (_ path: String) -> some View) {
        editors[kindID] = { AnyView(make($0)) }
    }

    public func addNewFile(_ title: String, kind: any DocumentKind.Type, symbol: String,
                           shortcut: KeyboardShortcut? = nil, defaultName: String) {
        newFileCommands.append(NewFileCommand(title: title, kind: kind, symbol: symbol, shortcut: shortcut,
                                              defaultName: defaultName))
    }

    /// "Import…" in the New menu; the chosen file is copied as is into the current folder
    public func addImport(_ title: String, kind: any DocumentKind.Type, symbol: String,
                          shortcut: KeyboardShortcut? = nil) {
        importCommands.append(ImportCommand(title: title, kind: kind, symbol: symbol, shortcut: shortcut))
    }

    /// A sidebar item; when selected the content area shows `content`. `id` must be unique across plugins
    public func addPanel(id: String, title: String, symbol: String, badgeTint: ColorToken? = nil,
                         badge: @escaping @MainActor () -> Int? = { nil },
                         content: @escaping @MainActor () -> some View) {
        precondition(!panels.contains { $0.id == id }, "重複註冊的 panel：\(id)")
        panels.append(Panel(id: id, title: title, symbol: symbol, badge: badge, badgeTint: badgeTint,
                            content: { AnyView(content()) }))
    }

    public func panel(id: String) -> Panel? {
        panels.first { $0.id == id }
    }

    public func addController(_ controller: any EditorController) {
        controllers.append(controller)
    }

    public func addMenu(_ title: String, sections: [[MenuItem]]) {
        menus.append(Menu(title: title, sections: sections))
    }

    /// Extracts the plugin's own index data from file content (`VaultIndex.records`). `id` must be unique across plugins
    public func addIndexContributor(_ contributor: some IndexContributor) {
        precondition(!indexContributors.contains { $0.id == contributor.id }, "重複註冊的 index contributor：\(contributor.id)")
        indexContributors.append(contributor)
    }

    /// Rewrites file content in the background; handles only local changes, and open files wait until they are left
    public func addContentFixer(_ fixer: some ContentFixer) {
        contentFixers.append(fixer)
    }

    /// When the vault has no `CLAUDE.md` the app creates it from these sections (never rewriting an existing one)
    public func addVaultGuide(_ markdown: String) {
        vaultGuides.append(markdown)
    }

    /// Makes `.easynotes/<name>/` take part in sync (the rest of `.easynotes/` is the local index, cache and sync state).
    /// These files have no DocumentKind and different content produces a conflict copy, so a plugin must be designed to avoid conflicts (for example each device writes only its own files)
    public func addSyncedMetaFolder(_ name: String) {
        precondition(!name.isEmpty && !name.contains("/") && name != "cache", "不能同步的資料夾：\(name)")
        if !syncedMetaFolders.contains(name) { syncedMetaFolders.append(name) }
    }

    // MARK: Queries

    /// Registering the same extension twice throws an error
    public func makeKinds() throws -> KindRegistry {
        try KindRegistry(kindInfos.map(\.kind) + companionKinds)
    }

    public var defaultKind: (any DocumentKind.Type)? {
        kindInfos.first?.kind
    }

    public func kindInfo(for kindID: String?) -> KindInfo? {
        kindInfos.first { $0.id == kindID }
    }

    public func symbol(for kindID: String?) -> String {
        kindInfo(for: kindID)?.symbol ?? "doc"
    }

    public func tint(for kindID: String?) -> KindTint {
        kindInfo(for: kindID)?.tint ?? .neutral
    }

    public func preview(for kindID: String?) -> (any DocumentPreviewProvider)? {
        kindID.flatMap { previews[$0] }
    }

    public func editor(for kindID: String?, path: String) -> AnyView? {
        kindID.flatMap { editors[$0] }?(path)
    }
}
