import Foundation
import Testing
@testable import EasyNotesCore

/// 核心測試不依賴任何外掛：用純文字的測試類型驗證 Vault 與 Registry
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
}
