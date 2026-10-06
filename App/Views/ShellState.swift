import EasyNotesCore
import EasyNotesUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The shell's transient UI state (not part of the vault): ⌘K, sheets, import, rename. Menu commands and views share one copy
@MainActor @Observable
final class ShellState {
    var showQuickOpen = false
    var showRecentlyDeleted = false
    var showSettings = false
    /// The "What's New" window (appears automatically on the first launch after an update, or from the menu)
    var whatsNew: WhatsNew?

    /// Import: the types the file picker allows (from plugins' `addImport`)
    var importTypes: [UTType] = []
    var isImporting = false

    var renaming: String?
    var newName = ""

    /// "Delete Immediately" waiting for the user's confirmation
    struct PurgeRequest: Identifiable {
        var path: String
        var isFolder: Bool
        var id: String { path }
    }
    var purging: PurgeRequest?

    func startImport(_ command: PluginRegistry.ImportCommand) {
        importTypes = command.kind.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        isImporting = true
    }

    func rename(_ path: String, current: String) {
        newName = current
        renaming = path
    }
}

// MARK: - Reveal in Finder / the Files app

#if os(macOS)
let revealTitle = L("在 Finder 中顯示")
#else
let revealTitle = L("在「檔案」App 中顯示")
#endif

/// macOS: select in Finder; iOS: open the containing folder with the Files app
@MainActor
func reveal(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.activateFileViewerSelecting([url])
    #else
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir)
    let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
    var components = URLComponents(url: folder, resolvingAgainstBaseURL: false)
    components?.scheme = "shareddocuments"
    if let target = components?.url { UIApplication.shared.open(target) }
    #endif
}

extension VaultStore {
    /// The name shown in the vault header: the vault folder's name
    var vaultName: String { fs.root.lastPathComponent }

    /// Title of the current location (last breadcrumb segment, page title)
    func title(for route: Route) -> String {
        switch route {
        case .all: L("所有文件")
        case .recents: L("最近")
        case .pinned: L("已釘選")
        case .folder(let path): (path as NSString).lastPathComponent
        case .tag(let tag): "#\(tag)"
        case .file(let path): displayName(path)
        case .panel(let id): plugins.panel(id: id)?.title ?? id
        }
    }

    func symbol(for route: Route) -> String {
        switch route {
        case .all: "doc.text"
        case .recents: "clock.arrow.circlepath"
        case .pinned: "pin"
        case .folder: "folder"
        case .tag: "number"
        case .file(let path): plugins.symbol(for: kindID(path))
        case .panel(let id): plugins.panel(id: id)?.symbol ?? "square.grid.2x2"
        }
    }

    /// Breadcrumb: folder / … / file name; pages that are not vault paths have only a title
    func breadcrumb(for route: Route) -> [String] {
        switch route {
        case .file(let path), .folder(let path):
            var parts = path.split(separator: "/").map(String.init)
            if case .file = route, !parts.isEmpty { parts[parts.count - 1] = displayName(path) }
            return parts
        default:
            return [title(for: route)]
        }
    }
}
