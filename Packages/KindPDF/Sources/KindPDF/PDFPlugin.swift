import EasyNotesUI
import SwiftUI

/// .pdf + .pdf.ink 標註旁檔（見 architecture/pdf.md）。5a 只有模型與格式（`PDFKind`、`PDFInkKind`），檢視器完成（5b）才註冊 Kind。
public enum PDFPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
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
