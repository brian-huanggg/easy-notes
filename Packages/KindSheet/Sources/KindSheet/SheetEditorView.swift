import EasyNotesUI
import SwiftUI

/// 表格編輯器：RevoGrid（WebView）。非 UTF-8 的檔案唯讀，上方顯示說明與「轉成 UTF-8」
struct SheetEditorView: View {
    let path: String
    let kind: any SheetKind.Type
    @Environment(\.documentSession) private var session
    @State private var sheet: SheetSession?

    var body: some View {
        // 不能用 Group：sheet 還是 nil 時沒有子 view，onAppear 不會被呼叫
        ZStack {
            if let sheet {
                WebEditorContainer(host: sheet.host)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if sheet.isReadOnly { ReadOnlyBanner(sheet: sheet) }
                    }
            }
        }
        .onAppear {
            if sheet == nil, let session {
                sheet = SheetController.shared.open(path, delimiter: kind.delimiter, session: session)
            }
        }
        .onDisappear { SheetController.shared.release(path) }
    }
}

private struct ReadOnlyBanner: View {
    let sheet: SheetSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Palette.yellow)
            Text(sheet.encoding == .big5 ? L("Big5 編碼的檔案只能檢視") : L("無法辨識檔案的編碼，只能檢視"))
                .font(.callout)
                .foregroundStyle(Palette.warnDeep)
            Spacer(minLength: 8)
            if sheet.encoding == .big5 {
                Button(L("轉成 UTF-8")) { sheet.convertToUTF8() }
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.warnSoft, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}
