import SwiftUI

/// App 的外觀偏好：跟隨系統、淺色、深色。以 `@AppStorage("appTheme")` 儲存，不寫進 Vault。
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case light, dark, system

    public static let storageKey = "appTheme"

    public var id: String { rawValue }

    /// `nil` 代表跟隨系統
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

    /// 同步平台層的 appearance：`ColorToken.color`（平台動態色）與 WebView 的
    /// `prefers-color-scheme` 看的是 UIKit / AppKit 的 appearance，不會跟著 SwiftUI 的 `preferredColorScheme`。
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
    /// 套用外觀偏好，並在偏好改變時同步平台 appearance
    func appTheme(_ theme: AppTheme) -> some View {
        preferredColorScheme(theme.colorScheme)
            .onAppear { theme.applyPlatformAppearance() }
            .onChange(of: theme) { _, new in new.applyPlatformAppearance() }
    }
}
