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

/// 外殼的暫時 UI 狀態（不屬於 Vault）：⌘K、sheet、匯入、重新命名。選單指令與畫面共用同一份
@MainActor @Observable
final class ShellState {
    var showQuickOpen = false
    var showRecentlyDeleted = false
    var showSettings = false

    /// 匯入：選檔視窗允許的類型（來自外掛的 `addImport`）
    var importTypes: [UTType] = []
    var isImporting = false

    var renaming: String?
    var newName = ""

    func startImport(_ command: PluginRegistry.ImportCommand) {
        importTypes = command.kind.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        isImporting = true
    }

    func rename(_ path: String, current: String) {
        newName = current
        renaming = path
    }
}

// MARK: - 在 Finder / 「檔案」App 中顯示

#if os(macOS)
let revealTitle = L("在 Finder 中顯示")
#else
let revealTitle = L("在「檔案」App 中顯示")
#endif

/// macOS：在 Finder 中選取；iOS：用「檔案」App 開啟所在資料夾
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
    /// Vault 標頭顯示的名稱：Vault 資料夾名稱
    var vaultName: String { fs.root.lastPathComponent }

    /// 目前位置的標題（麵包屑最後一段、頁面標題）
    func title(for route: Route) -> String {
        switch route {
        case .all: L("所有文件")
        case .recents: L("最近")
        case .pinned: L("釘選")
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

    /// 麵包屑：資料夾 / … / 檔名；非 Vault 路徑的頁面只有標題
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
