import SwiftUI

/// 一個有深淺兩組值的顏色 token，名稱與 `design/easy-notes-ui.pen` 的 variable 相同。
/// 當作 ShapeStyle 使用時依環境的 `colorScheme` 解析（`.foregroundStyle(Palette.textPrimary)`），
/// 需要 `Color` 的 API（`.tint`）用 `.color`。同一組值也輸出成 CM6 的 CSS variables（`Palette.css`）。
public struct ColorToken: ShapeStyle, Hashable, Sendable {
    /// Pen variable 名稱，也是 CSS variable 名稱（`--bg-canvas`）
    public let name: String
    public let light: String
    public let dark: String
    private let lightRGBA: RGBA
    private let darkRGBA: RGBA

    /// `light`、`dark`：`#RRGGBB` 或 `#RRGGBBAA`
    public init(_ name: String, light: String, dark: String) {
        self.name = name
        self.light = light
        self.dark = dark
        lightRGBA = RGBA(hex: light)
        darkRGBA = RGBA(hex: dark)
    }

    /// 透明；三元運算中與其他 token 同型別時使用
    public static let clear = ColorToken("clear", light: "#00000000", dark: "#00000000")

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        rgba(for: environment.colorScheme).resolved
    }

    func rgba(for scheme: ColorScheme) -> RGBA {
        scheme == .dark ? darkRGBA : lightRGBA
    }

    /// 跟隨系統深淺色的平台動態顏色，給只接受 `Color` 的 API
    public var color: Color {
        #if os(iOS)
        Color(uiColor: UIColor { [lightRGBA, darkRGBA] traits in
            (traits.userInterfaceStyle == .dark ? darkRGBA : lightRGBA).platform
        })
        #else
        Color(nsColor: NSColor(name: nil) { [lightRGBA, darkRGBA] appearance in
            (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkRGBA : lightRGBA).platform
        })
        #endif
    }

    public static func == (a: Self, b: Self) -> Bool { a.name == b.name && a.light == b.light && a.dark == b.dark }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

struct RGBA: Hashable, Sendable {
    let r, g, b, a: Double

    init(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 6 { s += "FF" }
        let v = UInt32(s, radix: 16) ?? 0
        r = Double((v >> 24) & 0xFF) / 255
        g = Double((v >> 16) & 0xFF) / 255
        b = Double((v >> 8) & 0xFF) / 255
        a = Double(v & 0xFF) / 255
    }

    var resolved: Color.Resolved {
        Color.Resolved(colorSpace: .sRGB, red: Float(r), green: Float(g), blue: Float(b), opacity: Float(a))
    }

    #if os(iOS)
    var platform: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    #else
    var platform: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    #endif

    /// CSS 的 `rgb()` / `rgba()`
    var css: String {
        let rgb = "\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded()))"
        return a >= 1 ? "rgb(\(rgb))" : "rgba(\(rgb), \(String(format: "%.3g", a)))"
    }
}
