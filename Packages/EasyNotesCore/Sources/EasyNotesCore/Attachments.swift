import Foundation

/// Attachments (cover, inserted images) live in the vault root's `Attachments/`.
/// Older versions used `附件/`: not moved and links not rewritten; when a file is not found in `Attachments/` on read, `附件/` is tried.
/// Both names are paths, referenced by links and synced across devices, and never change with the UI language.
public enum Attachments {
    public static let folder = "Attachments" // l10n:fixed
    public static let legacyFolder = "附件" // l10n:fixed

    /// Image extensions (lowercase) that can be shown embedded with `![[x.png]]`
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif"] // l10n:fixed

    /// The target path of `![[x.png]]` (same as the editor's `linkCards.ts`): without `/` it is in `Attachments/`, with `/` it is a vault-relative path
    public static func embedPath(_ target: String) -> String {
        target.contains("/") ? target : folder + "/" + target
    }

    /// `Attachments/a.png` → `附件/a.png`; nil when not under `Attachments/`
    public static func legacyPath(for path: String) -> String? {
        let prefix = folder + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return legacyFolder + "/" + path.dropFirst(prefix.count)
    }
}
