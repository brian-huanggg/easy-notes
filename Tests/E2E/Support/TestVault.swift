import Foundation
import XCTest

/// 一個測試用的 Vault 資料夾。App 以 `-EasyNotesVaultRoot` 開啟它，測試直接讀寫磁碟上的檔案來驗證結果
/// （檔案即真相：斷言看檔案，不看畫面）。
///
/// 位置：iOS 模擬器用 `SIMULATOR_SHARED_RESOURCES_DIRECTORY`（模擬器內所有 App 都能讀寫），
/// macOS 用暫存資料夾（App 與測試程序都沒有沙盒）。
final class TestVault: Sendable {
    let root: URL

    init(_ name: String = "vault") {
        root = Self.baseDirectory.appending(path: "\(name)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 不產生首次啟動的範例內容，測試只看自己放的檔案
        write("", to: ".easynotes/seeded")
    }

    static var baseDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["SIMULATOR_SHARED_RESOURCES_DIRECTORY"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "EasyNotesE2E", directoryHint: .isDirectory)
    }

    func url(_ path: String) -> URL { root.appending(path: path) }

    // MARK: 讀寫（扮演 Finder / Claude Code 等外部工具）

    func write(_ text: String, to path: String) {
        write(Data(text.utf8), to: path)
    }

    func write(_ data: Data, to path: String) {
        let target = url(path)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: target, options: .atomic)
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: url(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path(percentEncoded: false))
    }

    func remove(_ path: String) {
        try? FileManager.default.removeItem(at: url(path))
    }

    /// Vault 內所有檔案（相對路徑），不含 `.easynotes/` 與其他隱藏檔
    func files() -> Set<String> {
        var result = Set<String>()
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
        let prefix = root.standardizedFileURL.path(percentEncoded: false)
        while let file = walker?.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            var path = file.standardizedFileURL.path(percentEncoded: false)
            if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
            result.insert(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        }
        return result
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - 等待

/// 等到 `condition` 成立（輪詢只在測試端；App 端不輪詢）。逾時回傳 false。
/// 轉動 run loop 而不是 sleep，XCTest 與 XCUI 的事件照常處理
@MainActor @discardableResult
func waitUntil(timeout: TimeInterval = E2ETestCase.timeout, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return condition()
}
