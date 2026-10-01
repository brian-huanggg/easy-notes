import SwiftUI

/// 外殼的顏色 tokens，數值照 `design/easy-notes-ui.pen` 的 variables（`mode: light / dark`）。
/// 改設計稿的顏色時，同步改這裡；名稱保持與 Pen 相同，方便對照。
public enum Palette {
    // MARK: 背景
    public static let bgCanvas = ColorToken("bg-canvas", light: "#FFFFFF", dark: "#1F1F1E")
    public static let bgSidebar = ColorToken("bg-sidebar", light: "#F4F3F0", dark: "#181817")
    public static let bgPanel = ColorToken("bg-panel", light: "#FAF9F7", dark: "#252524")
    public static let bgHover = ColorToken("bg-hover", light: "#EAE8E3", dark: "#2E2E2C")
    public static let bgSelected = ColorToken("bg-selected", light: "#E7EEFC", dark: "#1D3358")

    // MARK: 邊框
    public static let border = ColorToken("border", light: "#E7E4DF", dark: "#343431")
    public static let borderStrong = ColorToken("border-strong", light: "#D9D5CE", dark: "#49483F")

    // MARK: 文字
    public static let textPrimary = ColorToken("text-primary", light: "#1D1C1A", dark: "#F2F1ED")
    /// 內文段落（比 primary 淡一階）
    public static let textBody = ColorToken("text-body", light: "#35332F", dark: "#DCDAD6")
    public static let textSecondary = ColorToken("text-secondary", light: "#6A6761", dark: "#A5A29B")
    public static let textTertiary = ColorToken("text-tertiary", light: "#9D9890", dark: "#75726B")

    // MARK: Accent
    public static let accent = ColorToken("accent", light: "#2C6BE8", dark: "#5E92F7")
    public static let accentSoft = ColorToken("accent-soft", light: "#E7EEFC", dark: "#1D3358")
    /// accent-soft 底上的文字（callout）
    public static let accentDeep = ColorToken("accent-deep", light: "#1E4FB0", dark: "#AEC8FF")
    /// 釘選、標籤圓點
    public static let yellow = ColorToken("yellow", light: "#E8A52B", dark: "#F0B550")
    public static let warnSoft = ColorToken("warn-soft", light: "#F7EFDC", dark: "#3A2F16")
    public static let warnDeep = ColorToken("warn-deep", light: "#9A7B2E", dark: "#EBCB85")

    // MARK: Surface
    /// 浮在背景上的元素：按鈕、卡片、選單
    public static let surfaceRaised = ColorToken("surface-raised", light: "#FFFFFF", dark: "#2A2A28")
    /// 半透明浮動工具列、Tab Bar（搭配模糊）
    public static let surfaceGlass = ColorToken("surface-glass", light: "#FFFFFFF2", dark: "#2A2A28F2")
    public static let surfaceQuote = ColorToken("surface-quote", light: "#FBFAF8", dark: "#232322")
    /// 預覽佔位的灰條
    public static let skeleton = ColorToken("skeleton", light: "#EDEBE7", dark: "#2C2C2A")
    public static let overlay = ColorToken("overlay", light: "#1D1C1A14", dark: "#00000055")

    // MARK: 狀態（卡片排程、同步）
    public static let cardNew = ColorToken("card-new", light: "#2C6BE8", dark: "#5E92F7")
    public static let cardLearn = ColorToken("card-learn", light: "#D9622B", dark: "#E8864F")
    /// 也用在「已同步」
    public static let cardDue = ColorToken("card-due", light: "#3E8E5A", dark: "#5CAF79")
    public static let cardNewSoft = ColorToken("card-new-soft", light: "#E7EEFC", dark: "#1D3358")
    public static let cardLearnSoft = ColorToken("card-learn-soft", light: "#FBECE2", dark: "#3A2317")
    public static let cardDueSoft = ColorToken("card-due-soft", light: "#E4F0E9", dark: "#16301F")

    /// 所有外殼 tokens（不含 KindTint），用來輸出 CSS variables
    public static let all: [ColorToken] = [
        bgCanvas, bgSidebar, bgPanel, bgHover, bgSelected,
        border, borderStrong,
        textPrimary, textBody, textSecondary, textTertiary,
        accent, accentSoft, accentDeep, yellow, warnSoft, warnDeep,
        surfaceRaised, surfaceGlass, surfaceQuote, skeleton, overlay,
        cardNew, cardLearn, cardDue, cardNewSoft, cardLearnSoft, cardDueSoft,
    ]
}

/// 檔案類型的顏色：圖示、篩選 chip 用 `base`，縮圖底色與 Doc Row 圖塊用 `soft`。
/// 由外掛在 `addKind(_:symbol:tint:)` 時選定，App 不寫死哪個類型用哪個顏色。
/// 預設值以色相命名（不是以類型命名），對應設計稿的 `type-doc` / `type-board` / `type-pdf` / `type-csv`。
public struct KindTint: Hashable, Sendable {
    public let base: ColorToken
    public let soft: ColorToken

    public init(base: ColorToken, soft: ColorToken) {
        self.base = base
        self.soft = soft
    }

    /// 設計稿 `type-doc`
    public static let neutral = KindTint(
        base: ColorToken("type-doc", light: "#6A6761", dark: "#A5A29B"),
        soft: ColorToken("type-doc-soft", light: "#EFEDE9", dark: "#2E2E2C"))
    /// 設計稿 `type-board`
    public static let violet = KindTint(
        base: ColorToken("type-board", light: "#7B5BD6", dark: "#A48BF0"),
        soft: ColorToken("type-board-soft", light: "#F0EBFC", dark: "#2A2240"))
    /// 設計稿 `type-pdf`
    public static let red = KindTint(
        base: ColorToken("type-pdf", light: "#D1443A", dark: "#EE7A70"),
        soft: ColorToken("type-pdf-soft", light: "#FCECEA", dark: "#3A211E"))
    /// 設計稿 `type-csv`
    public static let green = KindTint(
        base: ColorToken("type-csv", light: "#2E8B6B", dark: "#4FB893"),
        soft: ColorToken("type-csv-soft", light: "#E4F2ED", dark: "#16322A"))

    public static let presets: [KindTint] = [.neutral, .violet, .red, .green]
}
