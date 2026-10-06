import EasyNotesCore
import Foundation
import SwiftUI

/// The only entry for plugins to reach the vault, implemented by the app. Plugins do not import the app and never touch the network directly.
@MainActor
public protocol DocumentSession: AnyObject {
    func readData(_ path: String) -> Data
    /// Writes happen in the background; after writing the index and sync queue are updated
    func write(_ data: Data, to path: String)
    /// `[[link]]`: opens it if found, otherwise creates it
    func openLink(_ target: String)
    /// Shows search results in the sidebar, for example when clicking a #tag
    func search(_ query: String)
    /// Last modification time (the header's "edited N minutes ago")
    func modified(_ path: String) -> Date?
    /// Copies a file from outside the vault (for example a cover image) into the vault's attachments folder and returns the vault path;
    /// a file already inside the vault returns its path as is
    func importAttachment(_ url: URL) async -> String?
    /// Reads a file in the vault in the background, for the WebView's `vault://` images; no I/O on the main thread
    var resourceReader: @Sendable (_ path: String) async -> Data? { get }
    /// Gets a file preview's image in the background (`DocumentPreview.image`, cached by content hash), for the WebView's `embed://`;
    /// returns nil when no preview is registered or there is no image
    var embedImageReader: @Sendable (_ path: String) async -> Data? { get }
    /// Gets a file's preview data in the background (`DocumentPreview`, cached by content hash), for whiteboard note cards; returns nil when no preview is registered
    var previewReader: @Sendable (_ path: String) async -> DocumentPreview? { get }
    /// A plugin reads and writes its own `.easynotes/<name>/` (for example Flashcards' review logs)
    var vault: VaultFS { get }
    /// The index (records, file tags); nil if creation failed
    var index: VaultIndex? { get }
    /// Opens a file and scrolls to line `line` (0-based), for example review's "Edit note"
    func open(_ path: String, line: Int?)
    /// Opens a file in the side panel next to the main content (a whiteboard's note card); a host without a side panel opens it normally
    func openBeside(_ path: String)
    /// A plugin wrote a file inside a folder registered with `addSyncedMetaFolder`: schedule an upload
    func metaChanged()
    /// A plugin moved a file inside the vault itself (for example a PDF adopting an orphan sidecar): notifies the sync layer to keep the file id and updates the index
    func fileMoved(from: String, to: String)
}

extension DocumentSession {
    public var embedImageReader: @Sendable (_ path: String) async -> Data? { { _ in nil } }

    public var previewReader: @Sendable (_ path: String) async -> DocumentPreview? { { _ in nil } }
    public func fileMoved(from: String, to: String) {}
    public func openBeside(_ path: String) { open(path, line: nil) }

    public func readText(_ path: String) -> String {
        String(decoding: readData(path), as: UTF8.self)
    }
}

/// The app notifies plugins through it: resident editors (for example the shared WebView), and plugins that are not editors but need to know about vault changes
/// (Flashcards). Default implementations do nothing and plugins override only what they need.
@MainActor
public protocol EditorController: AnyObject {
    /// Called once after the app creates the DocumentSession
    func attach(_ session: any DocumentSession)
    /// Called once when the first window appears. Platform views (for example a pre-warmed WebView) must not be created
    /// before this: `register` and `attach` run inside `App.init`, before UIKit has set up event handling, and a WKWebView
    /// made there crashes on its first touch on iPadOS 18 (`UIGestureGraphEdge`: "Invalid parameter not satisfying: targetNode")
    func launched()
    /// Sends changes not yet written back; called before rename, delete and going to the background
    func flush() async
    /// A file was changed by an external tool or sync
    func externalChange(path: String, data: Data)
    /// A file was renamed or deleted: drop the retained editing state
    func close(path: String)
    /// Candidates for `[[` autocomplete and data for link cards
    func linkTargetsChanged(_ targets: [LinkTarget])
    /// After the index updates: in-app edits, external changes, sync downloads (including synced files under `.easynotes/`)
    func vaultChanged(_ paths: Set<String>)
    /// In-app rename or move (file or folder); moves caused by sync are not notified
    func moved(from: String, to: String)
    /// `DocumentSession.open(_:line:)`: scrolls to the line after opening
    func reveal(path: String, line: Int)
}

extension EditorController {
    public func attach(_ session: any DocumentSession) {}
    public func launched() {}
    public func flush() async {}
    public func externalChange(path: String, data: Data) {}
    public func close(path: String) {}
    public func linkTargetsChanged(_ targets: [LinkTarget]) {}
    public func vaultChanged(_ paths: Set<String>) {}
    public func moved(from: String, to: String) {}
    public func reveal(path: String, line: Int) {}
}

/// The target of a `[[link]]`: the name (without extension) and the type, summary and time a link card shows.
/// The type's icon and color are obtained by the app from PluginRegistry, so the editor knows no other plugin.
public struct LinkTarget: Hashable, Sendable {
    public let name: String
    public let path: String
    /// The type's SF Symbol in the Registry
    public let symbol: String
    public let tint: KindTint
    /// A one-line summary from the plugin ("320 words", "24 rows")
    public let summary: String?
    public let modified: Date
    /// Content hash: the `embed:///…?h=<hash>` of an `![[x]]` embed; when content changes the URL changes and the WebView reloads
    public let hash: String?

    public init(name: String, path: String, symbol: String, tint: KindTint, summary: String?, modified: Date,
                hash: String? = nil) {
        self.name = name
        self.path = path
        self.symbol = symbol
        self.tint = tint
        self.summary = summary
        self.modified = modified
        self.hash = hash
    }
}

extension EnvironmentValues {
    @Entry public var documentSession: (any DocumentSession)? = nil
}
