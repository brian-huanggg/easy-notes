import SwiftUI

/// 把同一組 tokens 輸出成 CSS variables，讓 WebView 外掛（CM6、RevoGrid）與原生顏色一致。
/// 淺色放 `:root`，深色放 `prefers-color-scheme: dark`，WebView 自己跟隨系統切換，不必每次切換都經過 Bridge。
public enum ThemeCSS {
    /// `extra`：外掛額外的 tokens（例如 Registry 中各 Kind 的 tint）
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

    /// 系統字型：拉丁字 SF Pro，中文 fallback 蘋方-繁
    public static let fontStack = #"-apple-system, BlinkMacSystemFont, "PingFang TC", "Heiti TC", sans-serif"#

    private static func declarations(_ tokens: [ColorToken], _ scheme: ColorScheme, indent: String = "  ") -> String {
        tokens.map { "\(indent)--\($0.name): \($0.rgba(for: scheme).css);" }.joined(separator: "\n")
    }

    private static func css(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value))px" : "\(value)px"
    }
}
