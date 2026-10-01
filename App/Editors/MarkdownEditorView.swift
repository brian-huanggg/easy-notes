import SwiftUI

struct MarkdownEditorView: View {
    let path: String
    @Environment(VaultStore.self) private var store
    private let host = WebEditorHost.shared

    var body: some View {
        WebEditorContainer(host: host)
            .task(id: path) {
                host.load(id: path, text: store.readText(path))
            }
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("Benchmark 1 萬行") { host.benchmark(lines: 10_000) }
                        Button("Benchmark 5 萬行") { host.benchmark(lines: 50_000) }
                        Button("重新載入目前筆記") { host.load(id: path, text: store.readText(path)) }
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
        host.lastLoadMs.map { String(format: "%.1f ms", $0) } ?? "–"
    }
}
