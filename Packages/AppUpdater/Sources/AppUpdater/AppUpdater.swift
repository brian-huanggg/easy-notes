import Foundation
import Observation
#if os(macOS)
import Sparkle
#endif

/// Starts Sparkle and provides "Check for Updates…". iOS has no update channel (TestFlight), so `canCheck` is always false.
///
/// Starts only when `SUPublicEDKey` in Info.plist has a value: the update signing public key is `SPARKLE_PUBLIC_ED_KEY` in `project.yml`,
/// and a build without a generated key never checks for updates over the network.
@MainActor @Observable
public final class AppUpdater {
    public private(set) var canCheck = false

    #if os(macOS)
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?
    #endif

    /// - Parameter enabled: pass false in UI tests and similar, which never start it
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
