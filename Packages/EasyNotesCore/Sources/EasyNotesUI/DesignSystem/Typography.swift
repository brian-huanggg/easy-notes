import SwiftUI

/// 字級、字重、行高照設計稿；字型一律用系統字型（拉丁字 SF Pro、中文蘋方-繁）。
/// Pen 不支援蘋果字型，設計稿的 Inter 只是替代，不打包。
public struct TextStyle: Hashable, Sendable {
    public let size: CGFloat
    public let weight: Font.Weight
    /// 行高倍率（設計稿的 `lineHeight`）；nil = 系統預設
    public let lineHeight: CGFloat?
    /// 字距（pt）
    public let tracking: CGFloat
    public let uppercase: Bool

    public init(_ size: CGFloat, _ weight: Font.Weight = .regular, lineHeight: CGFloat? = nil,
                tracking: CGFloat = 0, uppercase: Bool = false) {
        self.size = size
        self.weight = weight
        self.lineHeight = lineHeight
        self.tracking = tracking
        self.uppercase = uppercase
    }

    public var font: Font { .system(size: size, weight: weight) }

    /// SwiftUI 的 lineSpacing 是行與行之間多出的距離
    var lineSpacing: CGFloat { lineHeight.map { max(0, ($0 - 1.2) * size) } ?? 0 }
}

public extension TextStyle {
    // MARK: 頁面
    /// Desktop 列表頁標題「All Documents」
    static let pageTitle = TextStyle(26, .bold)
    /// Mobile 大標題
    static let largeTitle = TextStyle(30, .bold)
    /// 頁面標題下的統計「24 documents · 4 folders」、麵包屑
    static let pageSubtitle = TextStyle(12.5)
    static let breadcrumb = TextStyle(12.5, .semibold)

    // MARK: 區段
    /// 「Pinned 4」「Recent Today」
    static let sectionTitle = TextStyle(13, .semibold)
    static let sectionDetail = TextStyle(12)
    /// 側邊欄「SPACES」「TAGS」
    static let groupLabel = TextStyle(10, .bold, tracking: 0.8, uppercase: true)

    // MARK: 元件
    /// 側邊欄項目
    static let sidebarItem = TextStyle(13, .medium)
    /// 計數、卡片副標、快捷鍵
    static let meta = TextStyle(11.5)
    static let metaMedium = TextStyle(11.5, .medium)
    /// Vault 標頭下的帳號、同步時間等最小字
    static let caption = TextStyle(10.5)
    static let cardTitle = TextStyle(13, .semibold)
    /// 篩選 chip、排序按鈕、See all
    static let control = TextStyle(12, .medium)
    /// 主要按鈕、選單項目
    static let button = TextStyle(12.5, .semibold)
    static let menuItem = TextStyle(12.5, .medium)
    /// 已儲存、標籤 pill
    static let pill = TextStyle(11, .medium)
    static let searchField = TextStyle(12.5)
    /// 空狀態
    static let emptyTitle = TextStyle(19, .semibold)
    static let emptyMessage = TextStyle(13, lineHeight: 1.5)

    // MARK: Mobile
    static let rowTitle = TextStyle(15, .semibold)
    static let rowMeta = TextStyle(12)
    static let tabLabel = TextStyle(10, .medium)
    static let tabLabelSelected = TextStyle(10, .semibold)
    static let mobileSearchField = TextStyle(14.5)

    // MARK: 文件（原生預覽用；CM6 用 CSS 的同一組數值）
    static let docTitle = TextStyle(34, .bold, lineHeight: 1.35)
    static let docHeading = TextStyle(19, .bold)
    static let docBody = TextStyle(15.5, lineHeight: 1.85)
    static let docMeta = TextStyle(12.5)
}

public extension View {
    /// 套用設計系統的字級、字重、行高與字距
    func textStyle(_ style: TextStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

/// 圓角、間距等尺寸 tokens
public enum Metrics {
    /// 設計稿 `radius-sm`：側邊欄項目、按鈕、輸入框
    public static let radiusSmall: CGFloat = 7
    /// 設計稿 `radius-md`：卡片、縮圖、Doc Row 圖塊
    public static let radiusMedium: CGFloat = 10
    /// 浮動選單、空資料夾的拖放區
    public static let radiusLarge: CGFloat = 14
    /// 浮動格式工具列、鍵盤工具列
    public static let radiusBar: CGFloat = 16

    public static let sidebarWidth: CGFloat = 250
    public static let toolbarHeight: CGFloat = 46
    /// 列表頁內容的左右邊距
    public static let contentPadding: CGFloat = 32
    /// 卡片網格的間距
    public static let gridSpacing: CGFloat = 20
    /// 文件內文欄寬
    public static let docColumnWidth: CGFloat = 716
}
