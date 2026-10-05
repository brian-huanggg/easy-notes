import SwiftUI

/// Emits the same tokens as CSS variables so WebView plugins (CM6, RevoGrid) match native colors.
/// Light goes in `:root` and dark in `prefers-color-scheme: dark`; the WebView follows the system itself, so no switch has to go through the Bridge.
public enum ThemeCSS {
    /// `extra`: extra tokens from plugins (for example each Kind's tint in the Registry)
    public static func stylesheet(extra: [ColorToken] = []) -> String {
        let tokens = Palette.all + extra
        return """
        :root {
        \(declarations(tokens, .light))
          --font-ui: \(fontStack);
          --font-mono: ui-monospace, "SF Mono", Menlo, monospace;
          --radius-sm: \(css(Metrics.radiusSmall));
          --radius-md: \(css(Metrics.radiusMedium));
          --doc-column: \(css(Metrics.docColumnWidth));
          --doc-title-size: \(css(TextStyle.docTitle.size));
          --doc-heading-size: \(css(TextStyle.docHeading.size));
          --doc-body-size: \(css(TextStyle.docBody.size));
          --doc-body-line: \(TextStyle.docBody.lineHeight ?? 1.6);
        }
        @media (prefers-color-scheme: dark) {
          :root {
        \(declarations(tokens, .dark, indent: "    "))
          }
        }
        """
    }

    /// System fonts: SF Pro for Latin text, PingFang TC as the Chinese fallback
    public static let fontStack = #"-apple-system, BlinkMacSystemFont, "PingFang TC", "Heiti TC", sans-serif"#

    private static func declarations(_ tokens: [ColorToken], _ scheme: ColorScheme, indent: String = "  ") -> String {
        tokens.map { "\(indent)--\($0.name): \($0.rgba(for: scheme).css);" }.joined(separator: "\n")
    }

    private static func css(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value))px" : "\(value)px"
    }
}
