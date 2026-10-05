import Foundation

/// The core behavior of each file type. The core layer (Vault, Index, Sync) knows file types only through this protocol.
/// Implementations live in plugins; editors are registered by plugins with EasyNotesUI's PluginRegistry, keeping Core free of UI dependencies and unit-testable.
public protocol DocumentKind: SendableMetatype {
    static var id: String { get }
    /// The full extension (without the leading dot), for example "md", "excalidraw"
    static var fileExtensions: [String] { get }
    /// Default content of a newly created file
    static func template(title: String) -> Data
    /// Extracts index information such as search text, links and tags
    static func index(_ data: Data, fileName: String) -> IndexEntry
    /// Three-way merge; nil means it cannot merge and the sync layer creates a conflict copy
    static func merge(base: Data?, local: Data, remote: Data) -> Data?
    /// When a note is renamed, updates links in the content that point at it; nil means nothing to change
    static func renameLinks(in data: Data, from oldName: String, to newName: String) -> Data?
    /// Sets or clears pinning leaving the rest of the content unchanged; nil means this type does not support pinning
    static func setPinned(_ pinned: Bool, in data: Data) -> Data?
    /// A companion (for example a PDF's annotation sidecar `x.pdf.ink`) returns its main file's path; default nil = an ordinary file.
    /// A companion's path must start with its main file's path (`x.pdf` + `.ink`), from which Core computes the new path on rename.
    /// Core does not show companions in the file tree, lists or search; rename, delete and restore of the main file handle them together; they are still indexed and synced as usual.
    static func companionOf(_ path: String) -> String?
}

/// `icon`, `pinned` and `summary` are decided by the plugin; Core only stores them and never interprets them
public struct IndexEntry: Equatable, Sendable {
    public var title: String
    public var plainText: String
    public var links: [String]
    public var tags: [String]
    /// Document icon (for example a frontmatter emoji)
    public var icon: String?
    public var pinned: Bool
    /// A one-line summary for the list card subtitle, for example "1,240 words"
    public var summary: String?

    public init(title: String, plainText: String, links: [String] = [], tags: [String] = [],
                icon: String? = nil, pinned: Bool = false, summary: String? = nil) {
        self.title = title
        self.plainText = plainText
        self.links = links
        self.tags = tags
        self.icon = icon
        self.pinned = pinned
        self.summary = summary
    }
}

/// The file-type table assembled by plugins at launch; immutable afterwards and usable on any thread.
public struct KindRegistry: Sendable {
    public enum RegistrationError: Error, Equatable {
        case duplicateExtension(String)
    }

    public let all: [any DocumentKind.Type]

    /// One extension can belong to only one Kind
    public init(_ kinds: [any DocumentKind.Type]) throws {
        var seen = Set<String>()
        for ext in kinds.flatMap({ $0.fileExtensions }) {
            guard seen.insert(ext.lowercased()).inserted else { throw RegistrationError.duplicateExtension(ext) }
        }
        all = kinds
    }

    public func kind(for path: String) -> (any DocumentKind.Type)? {
        let name = (path as NSString).lastPathComponent.lowercased()
        return all.first { kind in
            kind.fileExtensions.contains { name.hasSuffix("." + $0.lowercased()) }
        }
    }

    public func kind(for url: URL) -> (any DocumentKind.Type)? {
        kind(for: url.lastPathComponent)
    }

    public func kind(id: String) -> (any DocumentKind.Type)? {
        all.first { $0.id == id }
    }

    /// A companion's main file path; nil when not a companion
    public func mainFile(ofCompanion path: String) -> String? {
        kind(for: path)?.companionOf(path)
    }

    public func isCompanion(_ path: String) -> Bool {
        mainFile(ofCompanion: path) != nil
    }

    /// When the main file moves from `oldMain` to `newMain`, the new path of companion `companion` (main path replaced, suffix unchanged)
    public func companionPath(_ companion: String, from oldMain: String, to newMain: String) -> String? {
        guard companion.hasPrefix(oldMain), mainFile(ofCompanion: companion) == oldMain else { return nil }
        return newMain + companion.dropFirst(oldMain.count)
    }

    /// Removes the registered extension, for example "a/筆記.md" → "筆記"
    public func displayName(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        while !(name as NSString).pathExtension.isEmpty,
              all.contains(where: { $0.fileExtensions.contains((name as NSString).pathExtension.lowercased()) }) {
            name = (name as NSString).deletingPathExtension
        }
        return name
    }
}

extension DocumentKind {
    /// With no specific merge strategy: identical content counts as merged, otherwise it goes to a conflict copy
    public static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        local == remote ? local : nil
    }

    public static func renameLinks(in data: Data, from oldName: String, to newName: String) -> Data? {
        nil
    }

    public static func setPinned(_ pinned: Bool, in data: Data) -> Data? {
        nil
    }

    public static func companionOf(_ path: String) -> String? {
        nil
    }

    /// Whether pinning is supported (the list's pin menu shows only for supporting types)
    public static var supportsPinning: Bool {
        setPinned(true, in: template(title: "")) != nil
    }
}
