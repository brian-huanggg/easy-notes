import Foundation

/// Launch arguments for E2E (XCUITest); effective only in DEBUG, Release always behaves normally.
/// Argument names are in `LaunchKey` (UITestContract.swift, shared with the test target).
enum TestHooks {
    enum Sync: Equatable {
        /// Normal: Supabase (Sign in with Apple)
        case supabase
        /// No sync, no network
        case off
        /// Uses a folder as the remote (`FolderSyncBackend`), with the test process playing another device
        case folder(URL)
    }

    /// The vault chosen by the test (one temporary folder per test)
    static var vaultRoot: URL? {
        #if DEBUG
        UserDefaults.standard.string(forKey: LaunchKey.vaultRoot).map { URL(filePath: $0, directoryHint: .isDirectory) }
        #else
        nil
        #endif
    }

    static var sync: Sync {
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: LaunchKey.syncFolder) {
            return .folder(URL(filePath: folder, directoryHint: .isDirectory))
        }
        if UserDefaults.standard.string(forKey: LaunchKey.sync) == "off" { return .off }
        #endif
        return .supabase
    }

    /// In a UI test: animations off, so waiting for conditions is more stable
    static var isUITest: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: LaunchKey.uiTest)
        #else
        false
        #endif
    }
}
