import ExcalidrawKit

/// 白板的結構工具（`BoardEditor` 處理）。手寫不是工具：iOS 的畫筆按鈕切換 `BoardEditor.inking`，
/// 由 PencilKit 的工具盤選筆、橡皮擦與套索。拖曳建立的工具給 Mac 與鍵盤快捷鍵用；
/// iOS 工具列改為插在畫面中央（`BoardEditor.insert`）。
public enum BoardTool: String, CaseIterable, Sendable {
    case select, rectangle, ellipse, arrow, text, frame

    /// 拖曳建立元素的工具
    public var creates: Bool {
        switch self {
        case .rectangle, .ellipse, .arrow, .frame: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .select: L("選取")
        case .rectangle: L("矩形")
        case .ellipse: L("橢圓")
        case .arrow: L("箭頭")
        case .text: L("文字")
        case .frame: "Frame"
        }
    }
}

/// 工具列「形狀」面板插入的形狀
public enum BoardShape: String, CaseIterable, Identifiable, Sendable {
    case rectangle, roundedRectangle, ellipse, diamond, arrow, frame

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rectangle: L("矩形")
        case .roundedRectangle: L("圓角矩形")
        case .ellipse: L("橢圓")
        case .diamond: L("菱形")
        case .arrow: L("箭頭")
        case .frame: "Frame"
        }
    }

    public var systemImage: String {
        switch self {
        case .rectangle: "square"
        case .roundedRectangle: "app"
        case .ellipse: "circle"
        case .diamond: "diamond"
        case .arrow: "arrow.right"
        case .frame: "rectangle.dashed"
        }
    }
}

/// 編輯器的畫布背景：App 偏好設定（`@AppStorage`），所有白板共用、不寫進檔案；只在編輯器顯示
public enum BoardBackground: String, CaseIterable, Identifiable, Sendable {
    case none, grid, dots

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: L("無")
        case .grid: L("網格")
        case .dots: L("點狀")
        }
    }

    public var systemImage: String {
        switch self {
        case .none: "square"
        case .grid: "grid"
        case .dots: "circle.grid.3x3"
        }
    }
}

/// 非手寫模式下，Pencil 在空白處拖曳的範圍選取方式（App 偏好設定，工具列按鈕切換）
public enum SelectionShape: String, CaseIterable, Sendable {
    case rectangle, lasso

    public var title: String {
        switch self {
        case .rectangle: L("矩形選取")
        case .lasso: L("套索選取")
        }
    }

    public var systemImage: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .lasso: "lasso"
        }
    }

    public var toggled: SelectionShape { self == .rectangle ? .lasso : .rectangle }
}
