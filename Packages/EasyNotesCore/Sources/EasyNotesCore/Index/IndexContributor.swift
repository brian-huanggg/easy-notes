import Foundation

/// One index record a plugin extracted from file content. `value` is plugin-defined (usually JSON); Core only stores it and never interprets it.
public struct IndexRecord: Equatable, Sendable {
    /// Unique within one file and one contributor
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A plugin's index extension point (for example Flashcards extracting cards from md). Called for every file while indexing; results go in the generic records table.
public protocol IndexContributor: Sendable {
    /// The namespace of records; must not repeat across plugins
    var id: String { get }
    /// Increment when the extraction rules change: the whole index is rebuilt
    var version: Int { get }
    func records(path: String, kindID: String, data: Data) -> [IndexRecord]
}

/// A plugin rewrites file content in the background (for example Flashcards adding `^id` to cards).
/// The app calls it only for locally produced changes and files not being edited; nil means no change needed.
public protocol ContentFixer: Sendable {
    func fix(path: String, kindID: String, data: Data, index: VaultIndex) async -> Data?
}
