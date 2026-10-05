import Foundation

/// 附件（封面、插入的圖片）放在 Vault 根目錄的 `Attachments/`。
/// 舊版放在 `附件/`：不搬動、不改寫連結，讀取時找不到 `Attachments/` 的檔案才改找 `附件/`。
/// 兩個名稱都是路徑，被連結引用、跨裝置同步，不隨介面語言改變。
public enum Attachments {
    public static let folder = "Attachments" // l10n:fixed
    public static let legacyFolder = "附件" // l10n:fixed

    /// 可以用 `![[x.png]]` 嵌入顯示的圖片副檔名（小寫）
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif"] // l10n:fixed

    /// `![[x.png]]` 的目標路徑（與編輯器 `linkCards.ts` 相同）：沒有 `/` 時在 `Attachments/`，有 `/` 時是 Vault 相對路徑
    public static func embedPath(_ target: String) -> String {
        target.contains("/") ? target : folder + "/" + target
    }

    /// `Attachments/a.png` → `附件/a.png`；不在 `Attachments/` 底下時回傳 nil
    public static func legacyPath(for path: String) -> String? {
        let prefix = folder + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return legacyFolder + "/" + path.dropFirst(prefix.count)
    }
}
