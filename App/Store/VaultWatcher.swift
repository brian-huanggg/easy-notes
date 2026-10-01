import EasyNotesCore
import Foundation

#if os(macOS)
import CoreServices

/// 監看 Vault 的外部修改（Finder、VS Code、git…）。FSEvents 會收到所有寫入，
/// 不需要其他 App 使用 NSFileCoordinator。`.easynotes/`（索引、快取）的變動會被忽略。
final class VaultWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor @Sendable () -> Void

    init(root: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            guard list.prefix(count).contains(where: { !$0.contains("/\(VaultFS.metaFolder)/") }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.onChange() } }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [root.path(percentEncoded: false)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
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
    init(root: URL, onChange: @escaping @MainActor @Sendable () -> Void) {}
}
#endif
