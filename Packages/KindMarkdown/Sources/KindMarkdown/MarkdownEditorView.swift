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
    }
}
