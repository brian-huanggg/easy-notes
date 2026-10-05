import Foundation
import Testing
import WebKit
@testable import EasyNotesUI

/// Records the handler's responses; `finished` completes after didFinish / didFailWithError
private final class FakeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: HTTPURLResponse?
    var body = Data()
    var error: Error?
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    init(_ url: String) { request = URLRequest(url: URL(string: url)!) }

    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() { finish() }
    func didFailWithError(_ error: Error) { self.error = error; finish() }

    private func finish() {
        done = true
        continuation?.resume()
        continuation = nil
    }

    @MainActor func finished() async {
        if done { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
struct EmbedSchemeHandlerTests {
    nonisolated static let png = Data([0x89, 0x50, 0x4E, 0x47])

    private func run(_ url: String, read: @escaping @Sendable (String) async -> Data?) async -> FakeTask {
        let handler = EmbedSchemeHandler()
        handler.read = read
        let task = FakeTask(url)
        handler.webView(WKWebView(), start: task)
        await task.finished()
        return task
    }

    /// The same form as the web side: `embed:///` + encodeURIComponent per segment (not put in the host, so Chinese is not taken as a domain name and converted to punycode)
    static func url(_ path: String, hash: String) -> String {
        "embed:///" + path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
            .joined(separator: "/") + "?h=" + hash
    }

    @Test func servesPreviewImageForVaultPath() async {
        let task = await run(Self.url("白板/流程 1.excalidraw", hash: "abc123")) { path in
            path == "白板/流程 1.excalidraw" ? Self.png : nil
        }
        #expect(task.response?.statusCode == 200)
        #expect(task.response?.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(task.body == Self.png)
    }

    @Test func asciiPathInHostPosition() async {
        let task = await run("embed://board.excalidraw?h=1") { $0 == "board.excalidraw" ? Self.png : nil }
        #expect(task.response?.statusCode == 200)
    }

    @Test func missingImageIs404() async {
        let task = await run("embed://a.md?h=1") { _ in nil }
        #expect(task.response?.statusCode == 404)
        #expect(task.body.isEmpty)
    }

    @Test func rejectsPathsOutsideVault() async {
        let task = await run("embed://../secret.excalidraw") { _ in
            Issue.record("不應讀取 Vault 外的路徑")
            return Self.png
        }
        #expect(task.response?.statusCode == 404)
        #expect(EmbedSchemeHandler.path(of: URL(string: "embed://a/./b.excalidraw")!) == nil)
        #expect(EmbedSchemeHandler.path(of: URL(string: "vault://a.excalidraw")!) == nil)
    }
}
