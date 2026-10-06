import Foundation
import Testing
@testable import EasyNotesCore

/// Core tests depend on no plugin: a plain-text test type verifies Vault and Registry
enum TextKind: DocumentKind {
    static let id = "text"
    static let fileExtensions = ["txt"]

    static func template(title: String) -> Data {
        Data("\(title)\n".utf8)
    }

    static func index(_ data: Data, fileName: String) -> IndexEntry {
        IndexEntry(title: (fileName as NSString).deletingPathExtension, plainText: String(decoding: data, as: UTF8.self))
    }
}

enum OtherTextKind: DocumentKind {
    static let id = "other-text"
    static let fileExtensions = ["TXT"]
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry { IndexEntry(title: fileName, plainText: "") }
}

struct KindRegistryTests {
    @Test func unregisteredExtensionReturnsNil() throws {
        let kinds = try KindRegistry([TextKind.self])
        #expect(kinds.kind(for: "a/筆記.TXT")?.id == TextKind.id)
        #expect(kinds.kind(for: "a/筆記.md") == nil)
        #expect(kinds.kind(id: "md") == nil)
    }

    @Test func duplicateExtensionThrows() {
        #expect(throws: KindRegistry.RegistrationError.duplicateExtension("TXT")) {
            try KindRegistry([TextKind.self, OtherTextKind.self])
        }
    }

    @Test func displayNameStripsRegisteredExtensionsOnly() throws {
        let kinds = try KindRegistry([TextKind.self])
        #expect(kinds.displayName("a/筆記.txt") == "筆記")
        #expect(kinds.displayName("a/v1.2.txt") == "v1.2")
    }

    @Test func defaultRenameLinksDoesNothing() {
        #expect(TextKind.renameLinks(in: Data("[[a]]".utf8), from: "a", to: "b") == nil)
    }
}

struct VaultTests {
    @Test func createResolveAndSearch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultFS(root: root, kinds: try KindRegistry([TextKind.self]))

        let folder = try vault.createFolder(named: "生物")
        let a = try vault.create(kind: TextKind.self, title: "葉綠體", in: folder)
        let b = try vault.create(kind: TextKind.self, title: "葉綠體", in: folder)
        #expect(a == "生物/葉綠體.txt")
        #expect(b == "生物/葉綠體 2.txt")

        try vault.write(Data("葉綠體\n行光合作用的胞器".utf8), to: a)
        try vault.write(Data("未註冊的類型不會出現".utf8), to: "生物/光合.md")
        #expect(try vault.resolveLink("葉綠體") == a)
        #expect(try vault.search("光合").map(\.path) == [a])
        #expect(try vault.scan().first?.children?.count == 2)
    }

    @Test func nameFollowingTitleKeepsExtensionAndAvoidsCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultFS(root: root, kinds: try KindRegistry([TextKind.self]))

        let note = try vault.create(kind: TextKind.self, title: "未命名", in: "生物")
        #expect(vault.nameFollowing(title: "葉綠體", for: note) == "葉綠體.txt")
        #expect(vault.nameFollowing(title: "未命名", for: note) == nil)
        #expect(vault.nameFollowing(title: "a/b", for: note) == "a-b.txt")
        #expect(vault.nameFollowing(title: String(repeating: "葉", count: 100), for: note)?.utf8.count == 66 * 3 + 4)

        _ = try vault.create(kind: TextKind.self, title: "葉綠體", in: "生物")
        #expect(vault.nameFollowing(title: "葉綠體", for: note) == "葉綠體 2.txt")

        // Already numbered because the name was taken: stays as is
        let second = try vault.create(kind: TextKind.self, title: "葉綠體", in: "生物")
        #expect(second == "生物/葉綠體 2.txt")
        #expect(vault.nameFollowing(title: "葉綠體", for: second) == nil)

        // Case-only change: the same file on a case-insensitive volume
        let english = try vault.create(kind: TextKind.self, title: "cell", in: "生物")
        #expect(vault.nameFollowing(title: "Cell", for: english) == nil)
    }
}

/// Words separated by whitespace that start with `#` count as tags
enum TaggedKind: DocumentKind {
    static let id = "tagged"
    static let fileExtensions = ["tag"]
    static func template(title: String) -> Data { Data() }
    static func index(_ data: Data, fileName: String) -> IndexEntry {
        let text = String(decoding: data, as: UTF8.self)
        let tags = text.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("#") }.map { String($0.dropFirst()) }
        return IndexEntry(title: (fileName as NSString).deletingPathExtension, plainText: text, tags: tags)
    }
}

struct LibraryTests {
    @Test func importFileKeepsNameAndAvoidsCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultFS(root: root.appending(path: "vault"), kinds: try KindRegistry([TextKind.self]))
        let outside = root.appending(path: "講義.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("內容".utf8).write(to: outside)

        #expect(try vault.importFile(from: outside, in: "課程") == "課程/講義.txt")
        #expect(try vault.importFile(from: outside, in: "課程") == "課程/講義 2.txt")
        #expect(try vault.read("課程/講義 2.txt") == Data("內容".utf8))
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
    }

    @Test func filesByRecencyAndTag() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultFS(root: root, kinds: try KindRegistry([TaggedKind.self]))
        try vault.write(Data("#swift/ui".utf8), to: "a.tag")
        try vault.write(Data("#swift".utf8), to: "b.tag")
        try vault.write(Data("#reading".utf8), to: "c.tag")
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: vault.url(for: "a.tag").path(percentEncoded: false))

        let index = try VaultIndex(fs: vault)
        try await index.sync()
        let files = try await index.files()
        #expect(files.count == 3)
        #expect(files.last?.path == "a.tag")
        #expect(files.last?.mtime == old)
        #expect(Set(try await index.files(taggedWith: "swift").map(\.path)) == ["a.tag", "b.tag"])
        #expect(try await index.files(taggedWith: "reading").map(\.path) == ["c.tag"])
        #expect(try await index.fileTags() == ["a.tag": ["swift/ui"], "b.tag": ["swift"], "c.tag": ["reading"]])
    }
}
