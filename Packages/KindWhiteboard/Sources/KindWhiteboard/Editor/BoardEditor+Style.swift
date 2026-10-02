import Foundation

/// 樣式面板（見 Architecture「4c：樣式面板」）：修改選取元素的樣式，並記住上次的值給新元素用
extension BoardEditor {
    /// 選取元素（含形狀內的文字）目前的樣式
    var styleSummary: StyleSummary {
        document.scene.styleSummary(selection)
    }

    /// 修改選取元素的樣式，一筆 Undo
    func setStyle(_ change: StyleChange) {
        currentStyle[change.property] = change
        let ids = selection
        guard !ids.isEmpty else { return }
        operation("樣式") { $0.setStyle(ids, change) }
    }

    /// 連續修改（透明度滑桿拖曳中）：逐幀修改，`endStylePreview` 才註冊一筆 Undo
    func previewStyle(_ change: StyleChange) {
        currentStyle[change.property] = change
        let ids = selection
        guard !ids.isEmpty else { return }
        if !stylePreviewing {
            if textEditing != nil { finishTextEditing() }
            gestureBefore = document.scene.elements
            gestureSelection = selection
            stylePreviewing = true
        }
        perform { $0.setStyle(ids, change) }
    }

    func endStylePreview() {
        guard stylePreviewing else { return }
        stylePreviewing = false
        recordUndo("樣式")
    }

    /// 新元素套用上次的樣式（只套用適用的欄位）。`except`：插入面板已經明確選了的欄位（矩形 / 圓角矩形）
    func applyCurrentStyle(to el: inout Element, except skipped: Set<StyleProperty> = []) {
        let props = el.styleProperties
        for (property, change) in currentStyle where props.contains(property) && !skipped.contains(property) {
            el.apply(change)
        }
    }

    /// 新文字的字級、字色、對齊（文字框開始編輯時就用它們）
    var currentFontSize: Double {
        if case let .fontSize(size) = currentStyle[.fontSize] { size } else { Self.defaultFontSize }
    }

    var currentTextColor: String {
        if case let .textColor(color) = currentStyle[.textColor] { color } else { Self.defaultTextColor }
    }

    func currentTextAlign(default value: String) -> String {
        if case let .textAlign(align) = currentStyle[.textAlign] { align } else { value }
    }
}
