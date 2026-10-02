import EasyNotesUI
import SwiftUI

/// PDF 檢視器：原始 PDF + 標註（見 architecture/pdf.md）。iOS 與 macOS 共用 `PDFReaderCanvas`。
struct PDFReaderView: View {
    let path: String
    @Environment(\.documentSession) private var session
    @State private var document: PDFInkDocument?

    var body: some View {
        // 不能用 Group：document 還是 nil 時沒有子 view，onAppear 永遠不會被呼叫
        ZStack {
            if let document {
                PDFCanvas(document: document)
                    #if os(iOS)
                    .ignoresSafeArea(edges: .bottom)
                    #endif
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if document.hashMismatch { HashMismatchBanner(document: document) }
                    }
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
            Text("PDF 已變更，標註可能錯位")
                .font(.callout)
                .foregroundStyle(Palette.warnDeep)
            Spacer(minLength: 8)
            Button("保留標註") { document.keepAnnotations() }
                .buttonStyle(.borderless)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.warnSoft, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

#if os(iOS)
private struct PDFCanvas: UIViewRepresentable {
    let document: PDFInkDocument

    func makeUIView(context: Context) -> PDFReaderCanvas {
        PDFReaderCanvas(document: document)
    }

    func updateUIView(_ view: PDFReaderCanvas, context: Context) {
        _ = document.pdfRevision // 觀察：PDF 檔被換掉時重新載入
        view.reloadIfNeeded()
    }
}
#else
private struct PDFCanvas: NSViewRepresentable {
    let document: PDFInkDocument

    func makeNSView(context: Context) -> PDFReaderCanvas {
        PDFReaderCanvas(document: document)
    }

    func updateNSView(_ view: PDFReaderCanvas, context: Context) {
        _ = document.pdfRevision // 觀察：PDF 檔被換掉時重新載入
        view.reloadIfNeeded()
    }
}
#endif
