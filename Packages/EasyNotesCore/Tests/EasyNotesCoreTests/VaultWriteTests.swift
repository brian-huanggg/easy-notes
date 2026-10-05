import Foundation
import Testing
@testable import EasyNotesCore

/// App saves: when an external tool (Claude Code) just wrote and file watching has not notified yet, the external change is not overwritten
struct VaultWriteTests {
    let fs: VaultFS

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fs = VaultFS(root: root, kinds: try KindRegistry([NoteKind.self, AnnotationKind.self]))
    }

    func text(_ path: String) -> String? { (try? fs.read(path)).map { String(decoding: $0, as: UTF8.self) } }

    @Test func diskMatchesExpectedWritesAsIs() throws {
        try fs.write(Data("一\n".utf8), to: "a.note")
        let result = try fs.write(Data("一（改）\n".utf8), to: "a.note", expecting: Data("一\n".utf8), deviceName: "Mac")
        #expect(result.data == Data("一（改）\n".utf8))
        #expect(result.conflictCopy == nil)
        #expect(text("a.note") == "一（改）\n")
    }

    @Test func externalEditIsMergedNotOverwritten() throws {
        try fs.write(Data("一\n\n二（Claude）\n".utf8), to: "a.note") // The external tool has already written
        let result = try fs.write(Data("一（App）\n\n二\n".utf8), to: "a.note",
                                  expecting: Data("一\n\n二\n".utf8), deviceName: "Mac")
        #expect(text("a.note") == "一（App）\n\n二（Claude）\n")
        #expect(result.data == Data("一（App）\n\n二（Claude）\n".utf8))
        #expect(result.conflictCopy == nil)
    }

    @Test func overlappingEditKeepsDiskAndSavesConflictCopy() throws {
        try fs.write(Data("Claude 版\n".utf8), to: "a.note")
        let result = try fs.write(Data("App 版\n".utf8), to: "a.note", expecting: Data("原本\n".utf8), deviceName: "Mac")
        #expect(text("a.note") == "Claude 版\n")
        #expect(result.data == Data("Claude 版\n".utf8))
        let copy = try #require(result.conflictCopy)
        #expect(copy.hasPrefix("a (衝突 Mac ") && copy.hasSuffix(").note"))
        #expect(text(copy) == "App 版\n")
    }

    @Test func unknownBaseWritesAsIs() throws {
        try fs.write(Data("磁碟\n".utf8), to: "a.note")
        let result = try fs.write(Data("App\n".utf8), to: "a.note", expecting: nil, deviceName: "Mac")
        #expect(result.data == Data("App\n".utf8))
        #expect(text("a.note") == "App\n")
    }

    @Test func newFileIsCreated() throws {
        let result = try fs.write(Data("新\n".utf8), to: "資料夾/新.note", expecting: Data(), deviceName: "Mac")
        #expect(result.conflictCopy == nil)
        #expect(text("資料夾/新.note") == "新\n")
    }

    @Test func unregisteredTypeChangedOnDiskKeepsBoth() throws {
        try fs.write(Data("disk".utf8), to: "圖.png")
        let result = try fs.write(Data("app".utf8), to: "圖.png", expecting: Data("old".utf8), deviceName: "iPad")
        #expect(text("圖.png") == "disk")
        let copy = try #require(result.conflictCopy)
        #expect(copy.hasPrefix("圖 (衝突 iPad ") && copy.hasSuffix(").png"))
        #expect(text(copy) == "app")
    }
}
