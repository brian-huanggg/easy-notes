import SwiftUI

/// The app's appearance preference: follow system, light, dark. Stored with `@AppStorage("appTheme")` and never written to the vault.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case light, dark, system

    public static let storageKey = "appTheme"

    public var id: String { rawValue }

    /// `nil` means follow system
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public var title: String {
        switch self {
        case .system: L("跟隨系統")
        case .light: L("淺色")
        case .dark: L("深色")
        }
    }

    public var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Syncs the platform-level appearance: `ColorToken.color` (platform dynamic colors) and the WebView's
    /// `prefers-color-scheme` look at the UIKit / AppKit appearance, which does not follow SwiftUI's `preferredColorScheme`.
    @MainActor
    public func applyPlatformAppearance() {
        #if os(macOS)
        NSApp?.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        #else
        let style: UIUserInterfaceStyle = switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = style
            }
        }
        #endif
    }
}

public extension View {
    /// Applies the appearance preference and syncs the platform appearance when the preference changes
    func appTheme(_ theme: AppTheme) -> some View {
        preferredColorScheme(theme.colorScheme)
            .onAppear { theme.applyPlatformAppearance() }
            .onChange(of: theme) { _, new in new.applyPlatformAppearance() }
    }
}
