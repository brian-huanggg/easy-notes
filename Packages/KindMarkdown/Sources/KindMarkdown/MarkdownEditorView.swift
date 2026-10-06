import EasyNotesUI
#if os(iOS)
import PhotosUI
#endif
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
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

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
            .confirmationDialog(L("封面"), isPresented: isPicking { if case .cover = $0 { true } else { false } }) {
                Button(L("選擇圖片…")) { editor.picker = .coverFile }
                #if os(iOS)
                Button(L("照片圖庫")) { editor.picker = .photoLibrary(cover: true) }
                #endif
                if MarkdownEditor.clipboardHasImage {
                    Button(L("貼上剪貼簿的圖片")) { Task { await editor.pasteCover() } }
                        .keyboardShortcut("v", modifiers: .command)
                }
                if case .cover(hasCover: true) = editor.picker {
                    Button(L("移除封面"), role: .destructive) { editor.setFrontmatter("cover", nil) }
                }
            }
            .fileImporter(isPresented: isPicking { $0 == .coverFile || $0 == .image }, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let purpose = importPurpose
                Task {
                    if purpose == .image { await editor.insertImage(url) } else { await editor.chooseCover(url) }
                }
            }
            #if os(iOS)
            // The system picker runs out of process: no photo-library permission is requested
            .photosPicker(isPresented: isPicking { if case .photoLibrary = $0 { true } else { false } },
                          selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                let cover: Bool = { if case .photoLibrary(let cover) = importPurpose { cover } else { false } }()
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    await editor.importImage(data, asCover: cover)
                }
            }
            #endif
            .onChange(of: editor.picker) { _, picker in
                if picker == .coverFile || picker == .image { importPurpose = picker }
                if case .photoLibrary = picker { importPurpose = picker }
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
