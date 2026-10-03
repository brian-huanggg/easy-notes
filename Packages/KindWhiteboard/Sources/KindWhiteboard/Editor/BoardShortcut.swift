import CoreGraphics
import ExcalidrawKit
import Foundation

/// 白板的鍵盤快捷鍵（見 architecture/whiteboard.md「4c：macOS 宿主、快捷鍵、LOD」）。平台無關：
/// Mac 的 `keyDown` 與 iPad 外接鍵盤的 `UIKeyCommand` 都把按鍵換成 `BoardShortcut` 再交給 `BoardEditor.perform`。
enum BoardShortcut: Equatable {
    case tool(BoardTool)
    case delete
    case duplicate
    case selectAll
    case copy
    case cut
    case paste
    case escape

    /// 按鍵（`characters`，小寫）→ 快捷鍵。不帶修飾鍵：V R O A T F、Delete；
    /// ⌘：D 再製、A 全選、C / X / V 剪貼簿；Esc。Shift、⌃、⌥ 一律不處理（留給系統與輸入法）
    init?(_ characters: String, command: Bool, shift: Bool = false, control: Bool = false, option: Bool = false) {
        guard !control, !option else { return nil }
        let key = characters.lowercased()
        if command {
            guard !shift else { return nil }
            switch key {
            case "d": self = .duplicate
            case "a": self = .selectAll
            case "c": self = .copy
            case "x": self = .cut
            case "v": self = .paste
            default: return nil
            }
            return
        }
        guard !shift || key == "\u{1b}" else { return nil }
        switch key {
        case "v": self = .tool(.select)
        case "r": self = .tool(.rectangle)
        case "o": self = .tool(.ellipse)
        case "a": self = .tool(.arrow)
        case "t": self = .tool(.text)
        case "f": self = .tool(.frame)
        case "\u{8}", "\u{7f}", "\u{F728}": self = .delete // ⌫（Backspace、Delete）與 ⌦（forward delete）
        case "\u{1b}": self = .escape
        default: return nil
        }
    }
}

extension BoardEditor {
    /// 執行快捷鍵。文字編輯中不處理（回傳 false，讓文字框收到按鍵）；有處理回傳 true
    @discardableResult
    func perform(_ shortcut: BoardShortcut) -> Bool {
        if textEditing != nil {
            // 只有 Esc 例外：結束編輯
            guard shortcut == .escape else { return false }
            finishTextEditing()
            return true
        }
        switch shortcut {
        case let .tool(next):
            inking = false
            tool = next
        case .delete:
            guard !selection.isEmpty else { return false }
            deleteSelection()
        case .duplicate:
            guard !selection.isEmpty else { return false }
            inking = false
            duplicateSelection()
        case .selectAll:
            inking = false
            tool = .select
            selectAll()
        case .copy:
            guard let data = copySelection() else { return false }
            BoardPasteboard.set(string: String(decoding: data, as: UTF8.self))
        case .cut:
            guard let data = copySelection() else { return false }
            BoardPasteboard.set(string: String(decoding: data, as: UTF8.self))
            deleteSelection()
        case .paste:
            pasteFromPasteboard()
        case .escape:
            if isDragging {
                cancel()
            } else if tool != .select {
                tool = .select
            } else {
                clearSelection()
            }
        }
        return true
    }

    /// 剪貼簿：Excalidraw 的元素（含 excalidraw.com 複製的）或圖片，放在畫面中央
    func pasteFromPasteboard() {
        if let json = BoardPasteboard.string(), json.contains(ExcalidrawScene.clipboardType),
           paste(Data(json.utf8), center: CGPoint(x: visibleRect.midX, y: visibleRect.midY)) {
            inking = false
            tool = .select
            return
        }
        guard let data = BoardPasteboard.imageData() else { return }
        Task { await insertImage(data) }
    }
}
