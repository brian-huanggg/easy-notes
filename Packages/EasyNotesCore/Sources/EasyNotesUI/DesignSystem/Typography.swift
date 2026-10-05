import SwiftUI

/// Font size, weight and line height follow the design; fonts always use system fonts (SF Pro for Latin, PingFang TC for Chinese).
/// Pen does not support Apple fonts, so the design's Inter is only a stand-in and is not bundled.
public struct TextStyle: Hashable, Sendable {
    public let size: CGFloat
    public let weight: Font.Weight
    /// Line-height multiplier (the design's `lineHeight`); nil = system default
    public let lineHeight: CGFloat?
    /// Letter spacing (pt)
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

    /// SwiftUI's lineSpacing is the extra distance between lines
    var lineSpacing: CGFloat { lineHeight.map { max(0, ($0 - 1.2) * size) } ?? 0 }
}

public extension TextStyle {
    // MARK: Page
    /// Desktop list page title "All Documents"
    static let pageTitle = TextStyle(26, .bold)
    /// Mobile large title
    static let largeTitle = TextStyle(30, .bold)
    /// Stats under the page title "24 documents · 4 folders", breadcrumb
    static let pageSubtitle = TextStyle(12.5)
    static let breadcrumb = TextStyle(12.5, .semibold)

    // MARK: Section
    /// "Pinned 4", "Recent Today"
    static let sectionTitle = TextStyle(13, .semibold)
    static let sectionDetail = TextStyle(12)
    /// Sidebar "SPACES", "TAGS"
    static let groupLabel = TextStyle(10, .bold, tracking: 0.8, uppercase: true)

    // MARK: Components
    /// Sidebar item
    static let sidebarItem = TextStyle(13, .medium)
    /// Counts, card subtitles, shortcuts
    static let meta = TextStyle(11.5)
    static let metaMedium = TextStyle(11.5, .medium)
    /// The smallest text, such as the account and sync time under the vault header
    static let caption = TextStyle(10.5)
    static let cardTitle = TextStyle(13, .semibold)
    /// Filter chips, sort button, See all
    static let control = TextStyle(12, .medium)
    /// Primary buttons, menu items
    static let button = TextStyle(12.5, .semibold)
    static let menuItem = TextStyle(12.5, .medium)
    /// Saved, tag pills
    static let pill = TextStyle(11, .medium)
    static let searchField = TextStyle(12.5)
    /// Empty state
    static let emptyTitle = TextStyle(19, .semibold)
    static let emptyMessage = TextStyle(13, lineHeight: 1.5)

    // MARK: Mobile
    static let rowTitle = TextStyle(15, .semibold)
    static let rowMeta = TextStyle(12)
    static let tabLabel = TextStyle(10, .medium)
    static let tabLabelSelected = TextStyle(10, .semibold)
    static let mobileSearchField = TextStyle(14.5)

    // MARK: Document (for native previews; CM6 uses the same values in CSS)
    static let docTitle = TextStyle(34, .bold, lineHeight: 1.35)
    static let docHeading = TextStyle(19, .bold)
    static let docBody = TextStyle(15.5, lineHeight: 1.85)
    static let docMeta = TextStyle(12.5)
}

public extension View {
    /// Applies the design system's font size, weight, line height and letter spacing
    func textStyle(_ style: TextStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

/// Size tokens such as corner radius and spacing
public enum Metrics {
    /// Design `radius-sm`: sidebar items, buttons, inputs
    public static let radiusSmall: CGFloat = 7
    /// Design `radius-md`: cards, thumbnails, Doc Row tiles
    public static let radiusMedium: CGFloat = 10
    /// Floating menus, the drop zone of an empty folder
    public static let radiusLarge: CGFloat = 14
    /// Floating format toolbar, keyboard toolbar
    public static let radiusBar: CGFloat = 16

    public static let sidebarWidth: CGFloat = 250
    public static let toolbarHeight: CGFloat = 46
    /// Left and right margins of list page content
    public static let contentPadding: CGFloat = 32
    /// Gap of the card grid
    public static let gridSpacing: CGFloat = 20
    /// Document body column width
    public static let docColumnWidth: CGFloat = 716
}
