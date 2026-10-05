import EasyNotesCore
import Foundation

#if os(macOS)
import CoreServices

/// Watches the vault for external changes (Finder, VS Code, Claude Code, git…). FSEvents receives all writes,
/// so other apps need not use NSFileCoordinator. Reports only the paths the event carries (relative to the vault);
/// changes under `.easynotes/` (index, cache, sync state) are ignored.
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

    /// Absolute path → vault-relative path; the vault root, hidden files and `.easynotes/` return nil
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
/// iOS has no FSEvents; sync runs when the app returns to the foreground instead (see scenePhase in EasyNotesApp)
final class VaultWatcher: @unchecked Sendable {
    init(root: URL, onChange: @escaping @MainActor @Sendable (Set<String>) -> Void) {}
}
#endif
