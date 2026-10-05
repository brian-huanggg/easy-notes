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

/// The first line is the title and the rest is body; records how many times it was called
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

/// Always returns the same "image"
private final class ImagePreview: DocumentPreviewProvider, @unchecked Sendable {
    static let png = Data((0..<64).map { UInt8($0) })
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func makePreview(_ data: Data) -> DocumentPreview {
        lock.withLock { _calls += 1 }
        return DocumentPreview(lines: ["a"], image: Self.png)
    }

    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView { AnyView(EmptyView()) }
}

@MainActor
struct KindInfoTests {
    /// Filters, icons, type colors and previews come only from registered Kinds
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

        // A fresh app launch: read from disk, not recomputed
        let reopened = PreviewCache(directory: dir)
        #expect(await reopened.preview(kindID: "note", hash: "abc", provider: provider) { content } == first)
        #expect(provider.calls == 1)

        // Regenerates after deleting the cache folder, with the same result
        try FileManager.default.removeItem(at: dir)
        let rebuilt = PreviewCache(directory: dir)
        #expect(await rebuilt.preview(kindID: "note", hash: "abc", provider: provider) { content } == first)
        #expect(provider.calls == 2)
    }

    /// The image is stored as `<hash>.png` and the JSON records only `hasImage`; a deleted PNG is regenerated
    @Test func imageIsStoredAsSidePNG() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "preview-\(UUID().uuidString)")
        let provider = ImagePreview()
        let cache = PreviewCache(directory: dir)
        let first = await cache.preview(kindID: "board", hash: "h1", provider: provider) { Data("x".utf8) }
        #expect(first?.image == ImagePreview.png)

        let folder = dir.appending(path: "board-v1")
        let json = try String(decoding: Data(contentsOf: folder.appending(path: "h1.json")), as: UTF8.self)
        #expect(json.contains("hasImage") && !json.contains(ImagePreview.png.base64EncodedString()))
        #expect(try Data(contentsOf: folder.appending(path: "h1.png")) == ImagePreview.png)

        let reopened = PreviewCache(directory: dir)
        #expect(await reopened.preview(kindID: "board", hash: "h1", provider: provider) { Data() }?.image == ImagePreview.png)
        #expect(provider.calls == 1)

        try FileManager.default.removeItem(at: folder.appending(path: "h1.png"))
        let rebuilt = PreviewCache(directory: dir)
        #expect(await rebuilt.preview(kindID: "board", hash: "h1", provider: provider) { Data("x".utf8) }?.image == ImagePreview.png)
        #expect(provider.calls == 2)
    }

    @Test func unreadableFileGivesNil() async {
        let cache = PreviewCache(directory: FileManager.default.temporaryDirectory.appending(path: "preview-\(UUID().uuidString)"))
        struct Missing: Error {}
        #expect(await cache.preview(kindID: "note", hash: "x", provider: CountingPreview()) { throw Missing() } == nil)
    }
}
