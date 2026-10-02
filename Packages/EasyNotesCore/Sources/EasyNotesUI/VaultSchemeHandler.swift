import Foundation
import UniformTypeIdentifiers
import WebKit

/// `vault://<Vault 內相對路徑>`：讓 WebView 讀取 Vault 內的圖片（封面、嵌入圖片）。
/// 只允許 Vault 內路徑；讀檔在背景進行，不擋主執行緒。
@MainActor
final class VaultSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "vault"

    var read: (@Sendable (String) async -> Data?)?
    /// 已被 WebView 取消的請求（回應前要檢查，對已停止的 task 回應會丟例外）
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let path = Self.path(of: url), let read else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(task)
        Task {
            let data = await read(path)
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

    /// `vault://附件/a.jpg` 或 `vault:///附件/a.jpg` → `附件/a.jpg`；拒絕 `..` 與絕對路徑
    nonisolated static func path(of url: URL) -> String? {
        guard var raw = url.absoluteString.dropFirst(scheme.count + 1).removingPercentEncoding else { return nil }
        while raw.hasPrefix("/") { raw.removeFirst() }
        if let query = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) { raw = String(raw[..<query]) }
        let parts = raw.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.joined(separator: "/")
    }
}

/// `symbol:///<SF Symbol 名稱>`：讓 WebView 顯示 SF Symbol（例如文件 icon `sf:map`）。
/// 回傳黑色單色 PNG，網頁端當 CSS mask 用，顏色由 CSS 決定；名稱不存在時回傳 `doc.text`。
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
        // CSS mask 以 CORS 模式載入，頁面是 file://，沒有這個 header 時 WebKit 會丟掉圖片（icon 變成空白）
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
