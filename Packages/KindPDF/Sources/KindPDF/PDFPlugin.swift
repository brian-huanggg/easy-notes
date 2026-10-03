import EasyNotesUI
import SwiftUI

/// .pdf + .pdf.ink 標註旁檔（見 architecture/pdf.md）
public enum PDFPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        registry.addKind(PDFKind.self, name: "PDF", symbol: "doc.richtext", tint: .red)
        registry.addCompanionKind(PDFInkKind.self)
        registry.addPreview(for: PDFKind.id, PDFPreview())
        registry.addController(PDFController.shared)
        registry.addEditor(for: PDFKind.id) { PDFReaderView(path: $0).id($0) }
        registry.addImport(L("匯入 PDF…"), kind: PDFKind.self, symbol: "doc.richtext",
                           shortcut: KeyboardShortcut("o"))
        #if os(iOS)
        // Spike S4：DEBUG 或啟動參數 `-PDFSpike YES`（Release 實機量測用）
        if _isDebugAssertConfiguration() || UserDefaults.standard.bool(forKey: "PDFSpike") {
            registry.addPanel(id: "pdf-spike", title: "PDF Spike", symbol: "doc.richtext") {
                PDFOverlaySpikeView()
            }
        }
        #endif
    }
}
