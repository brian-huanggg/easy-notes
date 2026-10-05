import Foundation
import Observation
#if os(macOS)
import Sparkle
#endif

/// 啟動 Sparkle 並提供「檢查更新…」。iOS 沒有更新通道（TestFlight），`canCheck` 恆為 false。
///
/// 只有 Info.plist 的 `SUPublicEDKey` 有值才會啟動：更新的簽章公鑰是 `project.yml` 的 `SPARKLE_PUBLIC_ED_KEY`，
/// 還沒產生金鑰的建置不會連網檢查更新。
@MainActor @Observable
public final class AppUpdater {
    public private(set) var canCheck = false

    #if os(macOS)
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?
    #endif

    /// - Parameter enabled: UI 測試等情境傳 false，完全不啟動
    public init(enabled: Bool = true) {
        #if os(macOS)
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = SPUStandardUpdaterController(startingUpdater: enabled && !key.isEmpty,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
        guard enabled, !key.isEmpty else { return }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }
        #endif
    }

    public func checkForUpdates() {
        #if os(macOS)
        controller.checkForUpdates(nil)
        #endif
    }
}
