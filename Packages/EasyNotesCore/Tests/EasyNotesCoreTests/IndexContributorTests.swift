import Foundation
import Testing
@testable import EasyNotesCore

/// One record per line, key = line number
private struct LineContributor: IndexContributor {
    let id = "lines"
    var version = 1
    func records(path: String, kindID: String, data: Data) -> [IndexRecord] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").enumerated().map {
            IndexRecord(key: "\(path)#\($0.offset)", value: String($0.element))
        }
    }
}

struct IndexContributorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "contrib-\(UUID().uuidString)")
    var fs: VaultFS { VaultFS(root: root, kinds: try! KindRegistry([TextKind.self])) }
    var location: URL { root.appending(path: ".easynotes/cache/index.sqlite") }

    @Test func recordsFollowFileChanges() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try fs.write(Data("一\n二\n".utf8), to: "a.txt")
        let index = try VaultIndex(fs: fs, contributors: [LineContributor()])
        try await index.sync()
        #expect(try await index.records("lines").map(\.record.value) == ["一", "二"])
        #expect(try await index.paths(withKey: "a.txt#1", contributor: "lines") == ["a.txt"])

        try fs.write(Data("三\n".utf8), to: "a.txt")
        try await index.update("a.txt", data: Data("三\n".utf8))
        #expect(try await index.records("lines").map(\.record.value) == ["三"])

        try FileManager.default.removeItem(at: fs.url(for: "a.txt"))
        try await index.sync(paths: ["a.txt"])
        #expect(try await index.records("lines").isEmpty)
    }

    /// The contributor's version changes → the index is cleared and fully rebuilt on the next sync
    @Test func versionChangeRebuildsIndex() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try fs.write(Data("一\n".utf8), to: "a.txt")
        do {
            let index = try VaultIndex(fs: fs, contributors: [LineContributor()])
            #expect(try await index.sync().count == 1)
        }
        do {
            let index = try VaultIndex(fs: fs, contributors: [LineContributor()])
            #expect(try await index.sync().isEmpty)
        }
        let index = try VaultIndex(fs: fs, contributors: [LineContributor(version: 2)])
        #expect(try await index.sync() == ["a.txt"])
        #expect(try await index.records("lines").count == 1)
    }

    /// The display-text language changes → the index is cleared and rebuilt; the same language is kept
    @Test func languageChangeRebuildsIndex() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try fs.write(Data("一\n".utf8), to: "a.txt")
        do {
            let index = try VaultIndex(fs: fs, language: "zh-Hant")
            #expect(try await index.sync().count == 1)
        }
        do {
            let index = try VaultIndex(fs: fs, language: "zh-Hant")
            #expect(try await index.sync().isEmpty)
        }
        let index = try VaultIndex(fs: fs, language: "en")
        #expect(try await index.sync() == ["a.txt"])
    }
}
