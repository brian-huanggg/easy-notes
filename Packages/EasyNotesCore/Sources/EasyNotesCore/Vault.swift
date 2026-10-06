import Foundation

/// A node in the vault (folder or file). The UI identifies it by relative path; cross-device sync uses a separate stable file id (see SyncEngine).
public struct VaultNode: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isFolder: Bool
    public var children: [VaultNode]?

    public var displayName: String {
        isFolder ? name : (name as NSString).deletingPathExtension
    }
}

/// File system operations. Files are the truth: there is no database here, and every index can be rebuilt from files.
public struct VaultFS: Sendable {
    public let root: URL
    public let kinds: KindRegistry
    /// App settings and cache (like .obsidian/), not shown in the file tree
    public static let metaFolder = ".easynotes"

    public init(root: URL, kinds: KindRegistry) {
        self.root = root
        self.kinds = kinds
    }

    /// Whether a vault-relative path is safe: non-empty, not absolute, no `.` / `..` segments, no NUL or backslash.
    /// A path from remote (sync) or the Bridge must pass this check before any write or read, to avoid leaving the vault.
    public static func isSafe(path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    /// Turns a title into a single-path-segment file name: `/`, `\`, NUL become `-` and a leading `.` is removed;
    /// so a link title such as `[[../../x]]` cannot make a new file land outside the vault
    public static func safeFileName(_ title: String) -> String {
        let replaced = String(title.map { $0 == "/" || $0 == "\\" || $0 == "\0" ? "-" : $0 })
        let trimmed = String(replaced.drop { $0 == "." }).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    public func url(for path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    public func path(for url: URL) -> String {
        let base = root.standardizedFileURL.path(percentEncoded: false)
        let full = url.standardizedFileURL.path(percentEncoded: false)
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Device

    /// This device's id, stored in `.easynotes/device-id` (not synced); created on first call.
    /// `migrating`: the value to use when there is no device-id (the id older versions kept in `sync.sqlite`), so the id stays unchanged
    public func deviceID(migrating existing: String? = nil) throws -> String {
        let url = url(for: "\(Self.metaFolder)/device-id")
        if let data = try? Data(contentsOf: url) {
            let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        let id = existing ?? UUID().uuidString
        try write(Data((id + "\n").utf8), to: "\(Self.metaFolder)/device-id")
        return id
    }

    // MARK: Scan

    /// The file tree; companions (`DocumentKind.companionOf`) are not listed by default
    public func scan(includingCompanions: Bool = false) throws -> [VaultNode] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try children(of: root, includingCompanions: includingCompanions)
    }

    private func children(of dir: URL, includingCompanions: Bool) throws -> [VaultNode] {
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try items.compactMap { url -> VaultNode? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                return VaultNode(path: path(for: url), name: url.lastPathComponent, isFolder: true,
                                 children: try children(of: url, includingCompanions: includingCompanions))
            }
            guard kinds.kind(for: url) != nil else { return nil }
            if !includingCompanions, kinds.isCompanion(url.lastPathComponent) { return nil }
            return VaultNode(path: path(for: url), name: url.lastPathComponent, isFolder: false, children: nil)
        }
        .sorted { lhs, rhs in
            lhs.isFolder != rhs.isFolder
                ? lhs.isFolder
                : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func allFiles(includingCompanions: Bool = false) throws -> [VaultNode] {
        func flatten(_ nodes: [VaultNode]) -> [VaultNode] {
            nodes.flatMap { $0.isFolder ? flatten($0.children ?? []) : [$0] }
        }
        return flatten(try scan(includingCompanions: includingCompanions))
    }

    public struct FileStat: Sendable {
        public let path: String
        public let mtime: Double
        public let size: Int
    }

    public func fileStats() throws -> [FileStat] {
        // Companions are indexed as usual (so external edits and sidecars pulled by sync can notify the editor)
        try allFiles(includingCompanions: true).compactMap { try fileStat($0.path) }
    }

    public func fileStat(_ path: String) throws -> FileStat? {
        let values = try? url(for: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let values else { return nil }
        return FileStat(path: path, mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        size: values.fileSize ?? 0)
    }

    // MARK: Read / write

    public func read(_ path: String) throws -> Data {
        try Data(contentsOf: url(for: path))
    }

    /// Atomic write: write a temp file then replace, so a crash or power loss never leaves half a file
    public func write(_ data: Data, to path: String) throws {
        let target = url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    /// For app saves: when the disk content is no longer `expected` (an external tool just wrote and the app has not applied it yet) it is not overwritten directly,
    /// but `expected` is used as the base for `DocumentKind.merge`; if it cannot merge, the disk version stays and `data` is saved as a conflict copy.
    /// When `expected` is nil (the last content is unknown) it writes directly. Returns the content actually written at `path` and the conflict copy's path
    public func write(_ data: Data, to path: String, expecting expected: Data?,
                      deviceName: String) throws -> (data: Data, conflictCopy: String?) {
        guard let expected, let current = try? read(path), current != expected, current != data else {
            try write(data, to: path)
            return (data, nil)
        }
        if let merged = kinds.kind(for: path)?.merge(base: expected, local: data, remote: current) {
            if merged != current { try write(merged, to: path) }
            return (merged, nil)
        }
        let copy = conflictPath(for: path, deviceName: deviceName)
        try write(data, to: copy)
        return (current, copy)
    }

    /// `Note.md` → `Note (conflict iPad 2026-10-01).md`, numbered when it already exists
    public func conflictPath(for path: String, deviceName: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var stem = kinds.displayName(name)
        if stem == name { stem = (name as NSString).deletingPathExtension } // Unregistered types, for example .png
        let ext = String(name.dropFirst(stem.count))
        let date = Date().formatted(.iso8601.year().month().day())
        var n = 1
        while true {
            let suffix = n == 1 ? "" : " \(n)"
            let candidate = "\(stem) (\(SyncEngine.conflictMarker) \(deviceName) \(date)\(suffix))\(ext)"
            let full = dir.isEmpty ? candidate : "\(dir)/\(candidate)"
            if !exists(full) { return full }
            n += 1
        }
    }

    /// Creates a new non-colliding file in the folder and returns the relative path
    public func create(kind: any DocumentKind.Type, title: String, in folder: String = "") throws -> String {
        let ext = kind.fileExtensions[0]
        let stem = Self.safeFileName(title)
        var name = "\(stem).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: url(for: join(folder, name)).path(percentEncoded: false)) {
            name = "\(stem) \(n).\(ext)"
            n += 1
        }
        let path = join(folder, name)
        try write(kind.template(title: title), to: path)
        return path
    }

    /// Copies a file from outside the vault into `folder`, numbering on a name clash; returns the relative path
    public func importFile(from source: URL, in folder: String = "") throws -> String {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        func name(_ n: Int) -> String {
            let stem = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var n = 1
        while FileManager.default.fileExists(atPath: url(for: join(folder, name(n))).path(percentEncoded: false)) { n += 1 }
        let path = join(folder, name(n))
        let target = url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        return path
    }

    public func createFolder(named name: String, in folder: String = "") throws -> String {
        let path = join(folder, name)
        try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        return path
    }

    /// Rename; the file's companions are renamed together (see `companionMoves`)
    public func rename(_ path: String, to newName: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let newPath = join(parent, newName)
        let companions = companionMoves(from: path, to: newPath)
        try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        for move in companions where !exists(move.to) {
            try FileManager.default.moveItem(at: url(for: move.from), to: url(for: move.to))
        }
        return newPath
    }

    /// Moves to another folder (`""` = root) with the name unchanged; companions move together.
    /// Throws when the destination has an item with the same name or a folder is moved into itself
    public func move(_ path: String, toFolder folder: String) throws -> String {
        let newPath = join(folder, (path as NSString).lastPathComponent)
        guard newPath != path else { return path }
        guard folder != path, !folder.hasPrefix(path + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        guard !exists(newPath) else { throw CocoaError(.fileWriteFileExists) }
        let companions = companionMoves(from: path, to: newPath)
        try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        for move in companions where !exists(move.to) {
            try FileManager.default.moveItem(at: url(for: move.from), to: url(for: move.to))
        }
        return newPath
    }

    /// Delete (move to trash); the file's companions are deleted together
    public func trash(_ path: String) throws {
        let companions = companions(of: path)
        try FileManager.default.trashItem(at: url(for: path), resultingItemURL: nil)
        for companion in companions { try FileManager.default.trashItem(at: url(for: companion), resultingItemURL: nil) }
    }

    /// Delete for good, skipping the system trash (a file in the OS trash would still hold the content); the file's companions go with it.
    /// A folder is removed with everything in it. Keeps going when one item fails and throws the first error at the end.
    public func deleteImmediately(_ path: String) throws {
        var failure: (any Error)?
        for target in [path] + companions(of: path) where exists(target) {
            do { try FileManager.default.removeItem(at: url(for: target)) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Companions in the same folder as `path` whose main file is `path`
    public func companions(of path: String) -> [String] {
        let parent = (path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? root : url(for: parent)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        return names.map { join(parent, $0) }.filter { kinds.mainFile(ofCompanion: $0) == path }.sorted()
    }

    /// When the main file moves from `path` to `newPath`, the moves of each companion (folders are not handled: companions are already inside)
    public func companionMoves(from path: String, to newPath: String) -> [(from: String, to: String)] {
        companions(of: path).compactMap { c in kinds.companionPath(c, from: path, to: newPath).map { (c, $0) } }
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path(percentEncoded: false))
    }

    private func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    // MARK: Links and search (replaced by the SQLite FTS5 index later)

    /// Finds a file by [[name]]: compares the file name without extension, case-insensitive
    public func resolveLink(_ target: String) throws -> String? {
        let wanted = target.lowercased()
        return try allFiles().first { $0.displayName.lowercased() == wanted }?.path
    }

    public func search(_ query: String) throws -> [VaultNode] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return try allFiles().filter { node in
            if node.displayName.localizedCaseInsensitiveContains(q) { return true }
            guard let kind = kinds.kind(for: node.path),
                  let data = try? read(node.path) else { return false }
            return kind.index(data, fileName: node.name).plainText.localizedCaseInsensitiveContains(q)
        }
    }
}
