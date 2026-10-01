import EasyNotesCore
import Foundation

#if os(macOS)
import CoreServices

/// 監看 Vault 的外部修改（Finder、VS Code、Claude Code、git…）。FSEvents 會收到所有寫入，
/// 不需要其他 App 使用 NSFileCoordinator。只回報事件帶來的路徑（相對於 Vault），
/// `.easynotes/`（索引、快取、同步狀態）的變動會被忽略。
final class VaultWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let onChange: @MainActor @Sendable (Set<String>) -> Void

    init(root: URL, onChange: @escaping @MainActor @Sendable (Set<String>) -> Void) {
        self.root = root.resolvingSymlinksInPath()
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let changed = Set(list.prefix(count).compactMap(watcher.relativePath))
            guard !changed.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.onChange(changed) } }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [self.root.path(percentEncoded: false)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    /// 絕對路徑 → Vault 內相對路徑；Vault 根目錄、隱藏檔與 `.easynotes/` 回傳 nil
    private func relativePath(_ absolute: String) -> String? {
        let base = root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let full = absolute.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard full.hasPrefix(base + "/") else { return nil }
        let path = String(full.dropFirst(base.count + 1))
        guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        return path
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
#else
/// iOS 沒有 FSEvents；改在 App 回到前景時同步（見 EasyNotesApp 的 scenePhase）
final class VaultWatcher: @unchecked Sendable {
    init(root: URL, onChange: @escaping @MainActor @Sendable (Set<String>) -> Void) {}
}
#endif
