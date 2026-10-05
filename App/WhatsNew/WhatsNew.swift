import Foundation

/// 更新後第一次開啟時顯示的「新功能」。內容是 `App/Resources/WhatsNew.json`，
/// 由 `scripts/release.sh` 從 `docs/Changelog.md` 當版的區塊產生（Changelog 是唯一的來源，寫成繁體中文）。
struct WhatsNew: Codable, Identifiable, Equatable {
    struct Section: Codable, Identifiable, Equatable {
        /// Keep a Changelog 的章節名（Added / Changed / Fixed / Security）
        var name: String
        var items: [String]
        var id: String { name }

        var title: String {
            switch name {
            case "Added": L("新增")
            case "Changed": L("調整")
            case "Fixed": L("修正")
            case "Security": L("安全性")
            default: name
            }
        }
    }

    var version: String
    var date: String?
    var sections: [Section]
    var id: String { version }
}

extension WhatsNew {
    /// 最後一次顯示過「新功能」的版本（`CFBundleShortVersionString`）
    static let lastSeenKey = "lastSeenVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// 打包進 App 的內容；沒有、讀不出來或沒有任何項目時是 nil
    static func bundled(_ bundle: Bundle = .main) -> WhatsNew? {
        guard let url = bundle.url(forResource: "WhatsNew", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode(WhatsNew.self, from: data),
              notes.sections.contains(where: { !$0.items.isEmpty })
        else { return nil }
        return notes
    }

    /// 該不該顯示：目前版本比上次看過的新。沒有紀錄時，全新安裝不顯示（沒有「新」可言），
    /// 否則是從這個功能出現之前的版本更新上來，要顯示。
    static func shouldShow(current: String, lastSeen: String?, isFreshInstall: Bool) -> Bool {
        guard let lastSeen else { return !isFreshInstall }
        return current.compare(lastSeen, options: .numeric) == .orderedDescending
    }

    /// 啟動時呼叫：回傳要顯示的內容，並記下目前版本。降版時不改紀錄，再升上來才會再顯示。
    static func pendingOnLaunch(isFreshInstall: Bool,
                                defaults: UserDefaults = .standard,
                                current: String = currentVersion,
                                notes: WhatsNew? = bundled()) -> WhatsNew? {
        guard !current.isEmpty else { return nil }
        let lastSeen = defaults.string(forKey: lastSeenKey)
        let show = shouldShow(current: current, lastSeen: lastSeen, isFreshInstall: isFreshInstall)
        if lastSeen == nil || current.compare(lastSeen ?? "", options: .numeric) == .orderedDescending {
            defaults.set(current, forKey: lastSeenKey)
        }
        guard show, let notes, notes.version == current else { return nil }
        return notes
    }
}
