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
