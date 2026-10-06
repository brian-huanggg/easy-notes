import Foundation

/// MetricKit payloads kept on this device, one JSON file per payload, newest kept up to `limit`.
/// Lives outside the vault (the vault is watched, indexed and may be handed to other tools); never synced, never uploaded.
public struct DiagnosticsStore: Sendable {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 30) {
        self.directory = directory
        self.limit = limit
    }

    /// `~/Library/Application Support/<bundle id>/Diagnostics`
    public static func standard(bundleID: String = Bundle.main.bundleIdentifier ?? DiagnosticsLog.subsystem) throws -> DiagnosticsStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return DiagnosticsStore(directory: base.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "Diagnostics", directoryHint: .isDirectory))
    }

    /// Writes one payload (`kind` is `diagnostic` or `metric`) and prunes the oldest files beyond `limit`.
    @discardableResult
    public func save(kind: String, json: Data, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stamp(date)
        var url = directory.appending(path: "\(stamp)-\(kind).json")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            n += 1
            url = directory.appending(path: "\(stamp)-\(kind)-\(n).json")
        }
        try json.write(to: url, options: .atomic)
        prune()
        return url
    }

    /// Stored payloads, oldest first (the file name starts with a sortable timestamp).
    public func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func prune() {
        let all = files()
        guard all.count > limit else { return }
        for url in all.prefix(all.count - limit) { try? FileManager.default.removeItem(at: url) }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}
