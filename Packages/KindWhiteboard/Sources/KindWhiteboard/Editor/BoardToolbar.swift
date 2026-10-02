import ExcalidrawKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 白板工具列（Freeform 式，見 architecture/whiteboard.md「工具列改版」）：畫筆（手寫模式）| 便條紙、形狀、文字框、圖片 |
/// 有選取時的操作（樣式、再製、刪除）| Undo / Redo。導覽列下方獨立一排
struct BoardToolbar: View {
    let editor: BoardEditor
    @SwiftUI.Binding var selectionShape: SelectionShape
    var showsInk = true

    @State private var showsShapes = false
    @State private var showsStyle = false
    @State private var showsPhotos = false
    @State private var photo: PhotosPickerItem?
    @State private var showsFiles = false
    @State private var canUndo = false
    @State private var canRedo = false

    var body: some View {
        HStack(spacing: 6) {
            if showsInk {
                button(editor.inking ? L("結束手寫") : L("畫筆"),
                       editor.inking ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                       active: editor.inking) { editor.inking.toggle() }
            }
            // 圖示顯示目前的方式，點一下切換（只影響非手寫模式在空白處拖曳的範圍選取）
            // 手寫模式中按：先回到選取（不切換方式），之後再按才切換
            button(L("\(selectionShape.title)（點一下切換）"), selectionShape.systemImage, active: !editor.inking) {
                if editor.inking { editor.inking = false } else { selectionShape = selectionShape.toggled }
            }
            separator
            button(L("便條紙"), "note.text") { editor.insertStickyNote() }
            button(L("形狀"), "square.on.circle", active: showsShapes || editor.tool.creates && editor.tool != .text) { showsShapes = true }
                .popover(isPresented: $showsShapes) {
                    ShapePalette { shape in
                        showsShapes = false
                        editor.insert(shape)
                    }
                    .presentationCompactAdaptation(.popover)
                }
            button(L("文字框"), "character.textbox", active: editor.tool == .text) { editor.insertText() }
            imageMenu
            if !editor.selection.isEmpty {
                separator
                if !editor.styleSummary.isEmpty {
                    button(L("樣式"), "paintpalette", active: showsStyle) { showsStyle = true }
                        .popover(isPresented: $showsStyle) {
                            StylePanel(editor: editor)
                                .presentationCompactAdaptation(.popover)
                        }
                }
                button(L("再製"), "plus.square.on.square") { editor.duplicateSelection() }
                button(L("刪除"), "trash") { editor.deleteSelection() }
            }
            separator
            button(L("復原"), "arrow.uturn.backward") { editor.undoManager?.undo(); refreshUndo() }
                .disabled(!canUndo)
            button(L("重做"), "arrow.uturn.forward") { editor.undoManager?.redo(); refreshUndo() }
                .disabled(!canRedo)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear(perform: refreshUndo)
        // 不能聽 NSUndoManagerCheckpoint：canUndo / canRedo 本身會發出它，形成無限迴圈
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in refreshUndo() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in refreshUndo() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in refreshUndo() }
        .photosPicker(isPresented: $showsPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { if let data = try? await item.loadTransferable(type: Data.self) { await editor.insertImage(data) } }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await editor.insertImage(data) }
        }
    }

    private func refreshUndo() {
        canUndo = editor.undoManager?.canUndo ?? false
        canRedo = editor.undoManager?.canRedo ?? false
    }

    private var separator: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }

    /// 圖片不是常駐工具：選了來源就插入
    private var imageMenu: some View {
        Menu {
            Button(L("照片"), systemImage: "photo.on.rectangle") { showsPhotos = true }
            Button(L("檔案"), systemImage: "folder") { showsFiles = true }
            Button(L("貼上"), systemImage: "doc.on.clipboard") { editor.pasteFromPasteboard() }
        } label: {
            Image(systemName: "photo.on.rectangle.angled").frame(width: 34, height: 34)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(L("圖片"))
        .accessibilityLabel(L("圖片"))
    }

    private func button(_ title: String, _ image: String, active: Bool = false,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: image)
                .frame(width: 34, height: 34)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 「形狀」面板：只顯示圖示（名稱給 VoiceOver），點一下插在畫面中央
private struct ShapePalette: View {
    let pick: (BoardShape) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 3), spacing: 8) {
            ForEach(BoardShape.allCases) { shape in
                Button { pick(shape) } label: {
                    Image(systemName: shape.systemImage).font(.system(size: 32))
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(shape.title)
                .accessibilityLabel(shape.title)
            }
        }
        .padding(14)
    }
}

/// 右下角的背景選單：無、網格、點狀（App 偏好設定）
struct BoardBackgroundMenu: View {
    @SwiftUI.Binding var background: BoardBackground

    var body: some View {
        Menu {
            Picker(L("背景"), selection: $background) {
                ForEach(BoardBackground.allCases) { bg in
                    Label(bg.title, systemImage: bg.systemImage).tag(bg)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "circle.grid.3x3")
                .font(.system(size: 17))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(L("背景"))
        .accessibilityLabel(L("背景"))
    }
}

/// 系統剪貼簿（iOS / macOS）
enum BoardPasteboard {
    /// 依序嘗試的圖片格式（保留原始資料，交給 ImageIO 縮圖）
    private static let imageTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .webP]

    /// 有可貼上的東西（字串或圖片）。iOS 用 `hasStrings` / `hasImages`，不會跳出「貼上」權限提示
    static var hasContent: Bool {
        #if canImport(UIKit)
        UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
        #else
        true
        #endif
    }

    static func set(string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    static func string() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    static func imageData() -> Data? {
        #if canImport(UIKit)
        let board = UIPasteboard.general
        guard board.hasImages else { return nil }
        for type in imageTypes { if let data = board.data(forPasteboardType: type.identifier) { return data } }
        return board.image?.pngData()
        #else
        let board = NSPasteboard.general
        for type in imageTypes {
            if let data = board.data(forType: NSPasteboard.PasteboardType(type.identifier)) { return data }
        }
        return nil
        #endif
    }
}
