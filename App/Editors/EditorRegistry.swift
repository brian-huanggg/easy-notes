import EasyNotesCore
import SwiftUI

/// DocumentKind.id → 編輯器。新增檔案類型時，在核心註冊 DocumentKind，再在這裡加一個 case。
enum EditorRegistry {
    @MainActor @ViewBuilder
    static func editor(for path: String, store: VaultStore) -> some View {
        switch DocumentKinds.kind(for: store.fs.url(for: path))?.id {
        case MarkdownKind.id:
            MarkdownEditorView(path: path)
        case InkKind.id:
            InkEditorView(path: path).id(path)
        default:
            ContentUnavailableView("不支援的檔案類型", systemImage: "doc.questionmark")
        }
    }
}
