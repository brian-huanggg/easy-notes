import EasyNotesUI
import SwiftUI

struct MarkdownEditorView: View {
    let path: String
    @Environment(\.documentSession) private var session
    private let editor = MarkdownEditor.shared

    var body: some View {
        WebEditorContainer(host: editor.host)
            .task(id: path) {
                editor.load(id: path, text: session?.readText(path) ?? "")
            }
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("Benchmark 1 萬行") { editor.benchmark(lines: 10_000) }
                        Button("Benchmark 5 萬行") { editor.benchmark(lines: 50_000) }
                        Button("重新載入目前筆記") { editor.load(id: path, text: session?.readText(path) ?? "") }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                            Text(loadLabel).monospacedDigit()
                        }
                    }
                    .help("Spike S1：最近一次切換筆記在 JS 端的耗時")
                }
            }
    }

    private var loadLabel: String {
        editor.lastLoadMs.map { String(format: "%.1f ms", $0) } ?? "–"
    }
}
