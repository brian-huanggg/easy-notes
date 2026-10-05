import EasyNotesCore
import Foundation
import UniformTypeIdentifiers
import WebKit

/// `vault://<relative path inside the vault>`: lets the WebView read images in the vault (cover, embedded images).
/// Only vault paths are allowed; reads run in the background and never block the main thread.
@MainActor
final class VaultSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "vault"

    var read: (@Sendable (String) async -> Data?)?
    /// Requests the WebView has cancelled (check before responding; responding to a stopped task throws)
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let path = Self.path(of: url), let read else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(task)
        Task {
            var data = await read(path)
            // Older attachments are in `附件/`: when not found in `Attachments/` the old folder is tried (so name-only `![[x.png]]` does not break)
            if data == nil, let legacy = Attachments.legacyPath(for: path) { data = await read(legacy) }
            guard !stopped.contains(id) else { return }
            if let data {
                let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            } else {
                task.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    /// `vault://Attachments/a.jpg` or `vault:///Attachments/a.jpg` → `Attachments/a.jpg`; rejects `..` and absolute paths
    nonisolated static func path(of url: URL) -> String? {
        guard var raw = url.absoluteString.dropFirst(scheme.count + 1).removingPercentEncoding else { return nil }
        while raw.hasPrefix("/") { raw.removeFirst() }
        if let query = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) { raw = String(raw[..<query]) }
        let parts = raw.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.joined(separator: "/")
    }
}

/// `embed:///<relative path inside the vault (each segment percent-encoded)>?h=<content hash>`: the PNG (`DocumentPreview.image`) of embedded previews such as `![[x.excalidraw]]`.
/// The image is drawn by the plugin in the background and cached by hash; the WebView loads it itself without the Bridge. `h` only makes the URL change when content changes so
/// the WebView reloads; it is not read here. Answers 404 when the file has no registered preview or no image (the `<img>` fires error).
@MainActor
final class EmbedSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "embed"

    var read: (@Sendable (String) async -> Data?)?
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = Self.path(of: url)
        let read = read
        let id = ObjectIdentifier(task)
        Task {
            let data: Data? = if let path, let read { await read(path) } else { nil }
            guard !stopped.contains(id) else { return }
            stopped.remove(id)
            let headers = ["Content-Type": data == nil ? "text/plain" : "image/png",
                           "Content-Length": String(data?.count ?? 0)]
            task.didReceive(HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                            headerFields: headers)!)
            if let data { task.didReceive(data) }
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    /// The same rules as `vault://`: rejects `..` and absolute paths and drops the query
    nonisolated static func path(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let rewritten = VaultSchemeHandler.scheme + url.absoluteString.dropFirst(scheme.count)
        return URL(string: rewritten).flatMap(VaultSchemeHandler.path(of:))
    }
}

/// `symbol:///<SF Symbol name>`: lets the WebView show an SF Symbol (for example the document icon `sf:map`).
/// Returns a black monochrome PNG that the web side uses as a CSS mask, with the color decided by CSS; returns `doc.text` when the name does not exist.
@MainActor
final class SymbolSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "symbol"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var name = String(url.absoluteString.dropFirst(Self.scheme.count + 1)).removingPercentEncoding ?? ""
        while name.hasPrefix("/") { name.removeFirst() }
        if !DocIcon.symbolExists(name) { name = "doc.text" }
        guard let data = SymbolImage.png(name, pointSize: 64) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // A CSS mask loads in CORS mode and the page is file://, so without this header WebKit drops the image (the icon goes blank)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "image/png",
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
