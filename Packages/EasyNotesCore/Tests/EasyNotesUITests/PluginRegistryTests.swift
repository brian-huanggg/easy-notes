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
