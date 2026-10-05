import SwiftUI

/// A color token with light and dark values, named after the variable in `design/easy-notes-ui.pen`.
/// Used as a ShapeStyle it resolves by the environment's `colorScheme` (`.foregroundStyle(Palette.textPrimary)`);
/// APIs that need a `Color` (`.tint`) use `.color`. The same values are also emitted as CM6 CSS variables (`Palette.css`).
public struct ColorToken: ShapeStyle, Hashable, Sendable {
    /// The Pen variable name, which is also the CSS variable name (`--bg-canvas`)
    public let name: String
    public let light: String
    public let dark: String
    private let lightRGBA: RGBA
    private let darkRGBA: RGBA

    /// `light`, `dark`: `#RRGGBB` or `#RRGGBBAA`
    public init(_ name: String, light: String, dark: String) {
        self.name = name
        self.light = light
        self.dark = dark
        lightRGBA = RGBA(hex: light)
        darkRGBA = RGBA(hex: dark)
    }

    /// Transparent; used when it must have the same type as other tokens in a ternary
    public static let clear = ColorToken("clear", light: "#00000000", dark: "#00000000")

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        rgba(for: environment.colorScheme).resolved
    }

    func rgba(for scheme: ColorScheme) -> RGBA {
        scheme == .dark ? darkRGBA : lightRGBA
    }

    /// A platform dynamic color that follows system light / dark, for APIs that accept only `Color`
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

    /// CSS `rgb()` / `rgba()`
    var css: String {
        let rgb = "\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded()))"
        return a >= 1 ? "rgb(\(rgb))" : "rgba(\(rgb), \(String(format: "%.3g", a)))"
    }
}
