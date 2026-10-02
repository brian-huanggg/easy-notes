import EasyNotesUI
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownEditorView: View {
    let path: String
    @Environment(\.documentSession) private var session
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Bindable private var editor = MarkdownEditor.shared
    /// 檔案面板的用途；關閉面板時 picker 可能已先被清掉，所以另外記住
    @State private var importPurpose: MarkdownEditor.Picker?

    var body: some View {
        WebEditorContainer(host: editor.host)
            .overlay(alignment: .bottomTrailing) {
                if showsFloatingBar {
                    FormatBar(editor.formatItems, style: .floating)
                        .padding(24)
                }
            }
            .task(id: path) {
                editor.load(id: path, text: session?.readText(path) ?? "", modified: session?.modified(path))
            }
            .confirmationDialog("封面", isPresented: isPicking { if case .cover = $0 { true } else { false } }) {
                Button("選擇圖片…") { editor.picker = .coverFile }
                if MarkdownEditor.clipboardHasImage {
                    Button("貼上剪貼簿的圖片") { Task { await editor.pasteCover() } }
                        .keyboardShortcut("v", modifiers: .command)
                }
                if case .cover(hasCover: true) = editor.picker {
                    Button("移除封面", role: .destructive) { editor.setFrontmatter("cover", nil) }
                }
            }
            .fileImporter(isPresented: isPicking { $0 == .coverFile || $0 == .image }, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let purpose = importPurpose
                Task {
                    if purpose == .image { await editor.insertImage(url) } else { await editor.chooseCover(url) }
                }
            }
            .onChange(of: editor.picker) { _, picker in
                if picker == .coverFile || picker == .image { importPurpose = picker }
            }
            .sheet(isPresented: isPicking { if case .icon = $0 { true } else { false } }) {
                DocIconPicker(current: DocIcon(currentIcon)) { icon in
                    editor.setFrontmatter("icon", icon?.frontmatterValue)
                }
                .background(Palette.bgCanvas)
            }
    }

    /// iPhone 用鍵盤上方的 Format Bar；Mac 與 iPad 用右下的浮動工具列
    private var showsFloatingBar: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    private var currentIcon: String? {
        if case .icon(let current) = editor.picker { current } else { nil }
    }

    /// 某一種 picker 是否顯示中；關閉時清掉（檔案面板的結果在 completion 裡先讀取）
    private func isPicking(_ matches: @escaping (MarkdownEditor.Picker) -> Bool) -> Binding<Bool> {
        Binding(
            get: { editor.picker.map(matches) ?? false },
            set: { if !$0, let picker = editor.picker, matches(picker) { editor.picker = nil } }
        )
    }
}
