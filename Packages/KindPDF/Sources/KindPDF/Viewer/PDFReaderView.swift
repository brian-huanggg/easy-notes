import EasyNotesUI
import SwiftUI

/// PDF 檢視器：原始 PDF + 標註（見 architecture/pdf.md）。iOS 與 macOS 共用 `PDFReaderCanvas`。
struct PDFReaderView: View {
    let path: String
    @Environment(\.documentSession) private var session
    @State private var document: PDFInkDocument?
    @State private var handle = PDFCanvasHandle()
    /// iOS 手寫模式（工具列的畫筆）
    @State private var inking = false
    @State private var exportJob: PDFExportJob?

    var body: some View {
        // 不能用 Group：document 還是 nil 時沒有子 view，onAppear 永遠不會被呼叫
        ZStack {
            if let document {
                PDFCanvas(document: document, handle: handle)
                    #if os(iOS)
                    .ignoresSafeArea(edges: .bottom)
                    .onChange(of: inking) { _, on in handle.canvas?.setInking(on) }
                    .onChange(of: InkSettings.shared.spec) { _, spec in handle.canvas?.setTool(spec) }
                    // 浮動列蓋在頁面上，不改 PDFView 的 inset（切換工具時頁面不跳動）
                    .overlay(alignment: .top) { PDFFloatingRow(inking: inking, handle: handle) }
                    #else
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 8) {
                            Button { exportJob = PDFExportJob(document: document) } label: {
                                Label(L("匯出"), systemImage: "square.and.arrow.up")
                            }
                            .help(L("匯出含標註的 PDF"))
                            Button { handle.canvas?.addSticky() } label: {
                                Label(L("便利貼"), systemImage: "note.text")
                            }
                            .help(L("在目前頁新增便利貼"))
                        }
                        .controlSize(.large)
                        .padding(16)
                    }
                    #endif
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            #if os(iOS)
                            // 工具列獨立一排，在導覽列（檔名、設定）下方
                            PDFToolbar(inking: $inking, handle: handle) {
                                exportJob = PDFExportJob(document: document)
                            }
                            #endif
                            if document.hashMismatch { HashMismatchBanner(document: document) }
                        }
                    }
                    .sheet(item: $exportJob) { PDFExportSheet(job: $0) }
            }
        }
        .onAppear {
            if document == nil, let session {
                document = PDFController.shared.open(path, session: session)
            }
        }
        .onDisappear {
            document?.flush()
            PDFController.shared.close(path: path)
        }
    }
}

/// 旁檔記錄的 `pdfHash` 與目前的 PDF 不同：標註仍依頁碼顯示，按「保留標註」才以目前的 PDF 為準
private struct HashMismatchBanner: View {
    let document: PDFInkDocument

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.yellow)
            Text(L("PDF 已變更，標註可能錯位"))
                .font(.callout)
                .foregroundStyle(Palette.warnDeep)
            Spacer(minLength: 8)
            Button(L("保留標註")) { document.keepAnnotations() }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.warnSoft, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

/// SwiftUI 的按鈕找到畫布
@MainActor
final class PDFCanvasHandle {
    weak var canvas: PDFReaderCanvas?
}

#if os(iOS)
private struct PDFCanvas: UIViewRepresentable {
    let document: PDFInkDocument
    let handle: PDFCanvasHandle

    func makeUIView(context: Context) -> PDFReaderCanvas {
        let canvas = PDFReaderCanvas(document: document)
        handle.canvas = canvas
        return canvas
    }

    func updateUIView(_ view: PDFReaderCanvas, context: Context) {
        _ = document.pdfRevision // 觀察：PDF 檔被換掉時重新載入
        view.reloadIfNeeded()
    }
}
#else
private struct PDFCanvas: NSViewRepresentable {
    let document: PDFInkDocument
    let handle: PDFCanvasHandle

    func makeNSView(context: Context) -> PDFReaderCanvas {
        let canvas = PDFReaderCanvas(document: document)
        handle.canvas = canvas
        return canvas
    }

    func updateNSView(_ view: PDFReaderCanvas, context: Context) {
        _ = document.pdfRevision // 觀察：PDF 檔被換掉時重新載入
        view.reloadIfNeeded()
    }
}
#endif
