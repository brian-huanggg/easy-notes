import EasyNotesCore
import Foundation
import SwiftUI
import Testing
@testable import EasyNotesUI

private enum PDFLikeKind: DocumentKind {
    static let id = "pdf-like"
    static let fileExtensions = ["pdf"]
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
}

@MainActor
struct PluginRegistryTests {
    @Test func importsAndPanelsComeOnlyFromPlugins() {
        let registry = PluginRegistry()
        #expect(registry.importCommands.isEmpty)
        #expect(registry.panels.isEmpty)

        registry.addImport("匯入 PDF…", kind: PDFLikeKind.self, symbol: "doc.richtext",
                           shortcut: KeyboardShortcut("o"))
        registry.addPanel(id: "review", title: "複習", symbol: "rectangle.stack", badgeTint: Palette.cardDue,
                          badge: { 47 }) { Text("複習") }

        #expect(registry.importCommands.map(\.title) == ["匯入 PDF…"])
        #expect(registry.importCommands.first?.kind.id == PDFLikeKind.id)
        #expect(registry.panel(id: "review")?.badge() == 47)
        #expect(registry.panel(id: "missing") == nil)
    }
}

private enum NoteLikeKind: DocumentKind {
    static let id = "note-like"
    static let fileExtensions = ["note"]
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
}

/// 第一行當標題、其餘當內文；記錄被呼叫的次數
private final class CountingPreview: DocumentPreviewProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func makePreview(_ data: Data) -> DocumentPreview {
        lock.withLock { _calls += 1 }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return DocumentPreview(title: lines.first, lines: Array(lines.dropFirst()))
    }

    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView { AnyView(EmptyView()) }
}

@MainActor
struct KindInfoTests {
    /// 篩選、圖示、類型顏色、預覽都只來自已註冊的 Kind
    @Test func filtersAndPreviewsComeFromRegisteredKinds() {
        let registry = PluginRegistry()
        registry.addKind(NoteLikeKind.self, name: "筆記", symbol: "doc.text")
        registry.addKind(PDFLikeKind.self, name: "PDF", symbol: "doc.richtext", tint: .red)
        registry.addPreview(for: NoteLikeKind.id, CountingPreview())

        #expect(registry.kindInfos.map(\.name) == ["筆記", "PDF"])
        #expect(registry.defaultKind?.id == NoteLikeKind.id)
        #expect(registry.tint(for: PDFLikeKind.id) == .red)
        #expect(registry.symbol(for: "missing") == "doc")
        #expect(registry.preview(for: NoteLikeKind.id) != nil)
        #expect(registry.preview(for: PDFLikeKind.id) == nil)
    }
}

struct PreviewCacheTests {
    @Test func cachesByHashAndRegeneratesIdentically() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "preview-\(UUID().uuidString)")
        let provider = CountingPreview()
        let content = Data("# 標題\n第一行\n第二行".utf8)

        let cache = PreviewCache(directory: dir)
        let first = await cache.preview(kindID: "note", hash: "abc", provider: provider) { content }
        #expect(first == DocumentPreview(title: "# 標題", lines: ["第一行", "第二行"]))
        _ = await cache.preview(kindID: "note", hash: "abc", provider: provider) { Issue.record("不應重新讀檔"); return content }
        #expect(provider.calls == 1)

        // 新的 App 啟動：從磁碟讀，不重算
        let reopened = PreviewCache(directory: dir)
        #expect(await reopened.preview(kindID: "note", hash: "abc", provider: provider) { content } == first)
        #expect(provider.calls == 1)

        // 刪掉快取資料夾後重新產生，結果相同
        try FileManager.default.removeItem(at: dir)
        let rebuilt = PreviewCache(directory: dir)
        #expect(await rebuilt.preview(kindID: "note", hash: "abc", provider: provider) { content } == first)
        #expect(provider.calls == 2)
    }

    @Test func unreadableFileGivesNil() async {
        let cache = PreviewCache(directory: FileManager.default.temporaryDirectory.appending(path: "preview-\(UUID().uuidString)"))
        struct Missing: Error {}
        #expect(await cache.preview(kindID: "note", hash: "x", provider: CountingPreview()) { throw Missing() } == nil)
    }
}
