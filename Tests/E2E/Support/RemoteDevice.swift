import EasyNotesCore
import EasyNotesTestSupport
import Foundation

/// 「另一台裝置」：測試程序自己的 Vault + SyncEngine，和 App 共用同一個 `FolderSyncBackend` 資料夾。
/// 不 import 外掛（外掛之間、測試與外掛都不互相依賴）：`.md` 用以行合併的最小 Kind，與 Markdown 外掛的策略相同。
final class RemoteDevice: Sendable {
    let vault: TestVault
    let engine: SyncEngine

    init(name: String, backend: URL) throws {
        vault = TestVault("remote-\(name)")
        let fs = VaultFS(root: vault.root, kinds: try KindRegistry([LineMergedMarkdown.self]))
        engine = try SyncEngine(fs: fs, backend: try FolderSyncBackend(root: backend), userID: "e2e", deviceName: name)
    }

    func sync() async { await engine.sync() }
}

/// 資料夾 backend 的位置（App 以 `-EasyNotesSyncFolder` 指向同一處）
func makeBackendFolder() -> URL {
    let url = TestVault.baseDirectory.appending(path: "backend-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

enum LineMergedMarkdown: DocumentKind {
    static let id = "markdown"
    static let fileExtensions = ["md"]
    static func template(title: String) -> Data { Data("# \(title)\n".utf8) }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
    static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        guard let base else { return local == remote ? local : nil }
        return Diff3.merge(base: base, local: local, remote: remote)
    }
}
