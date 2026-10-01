import SwiftUI
import WebKit

/// 全 App 共用一個預先載入的 WKWebView（CodeMirror 6）。
/// 切換筆記只呼叫 `editor.load`，不重新載入頁面；打字不經過 Bridge，
/// JS 端在停止輸入 300ms 或失焦時才回報 `changed`。
@MainActor @Observable
final class WebEditorHost {
    static let shared = WebEditorHost()

    private(set) var isReady = false
    /// Spike S1 量測：JS 端切換文件耗時（ms）
    private(set) var lastLoadMs: Double?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored var onChanged: ((_ id: String, _ text: String) -> Void)?
    @ObservationIgnored var onOpenLink: ((_ target: String) -> Void)?
    @ObservationIgnored var onOpenTag: ((_ tag: String) -> Void)?
    @ObservationIgnored private var pendingLoad: (id: String, text: String)?
    @ObservationIgnored private var linkTargets: [String] = []
    @ObservationIgnored private let messageProxy = MessageProxy()

    private init() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(messageProxy, name: "bridge")
        #if os(iOS)
        webView = EditorWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // 捲動交給 CodeMirror 自己的 scroller，避免兩層捲動
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        webView.isInspectable = true // Safari → 開發 → 可檢查 WebView
        messageProxy.host = self

        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        } else {
            assertionFailure("Editor bundle missing; run `npm run build` in web/")
        }
    }

    // MARK: Swift → JS

    func load(id: String, text: String) {
        guard isReady else {
            pendingLoad = (id, text)
            return
        }
        call("editor.load(id, text)", ["id": id, "text": text])
    }

    /// 外部修改（Finder、其他編輯器、同步）後更新編輯器內容，保留游標與 undo
    func applyRemote(id: String, text: String) {
        call("editor.applyRemote(id, text)", ["id": id, "text": text])
    }

    /// `[[` 自動完成的候選清單
    func setLinkTargets(_ names: [String]) {
        linkTargets = names
        call("editor.setLinkTargets(names)", ["names": names])
    }

    func exec(_ command: String) {
        call("editor.exec(command)", ["command": command])
    }

    func focus() {
        call("editor.focus()")
    }

    func close(id: String) {
        call("editor.close(id)", ["id": id])
    }

    func benchmark(lines: Int) {
        call("editor.benchmark(lines)", ["lines": lines])
    }

    /// 等 JS 把尚未回報的變更送出；重新命名、刪除、進入背景前呼叫
    func flush() async {
        guard isReady else { return }
        _ = try? await webView.callAsyncJavaScript("editor.flush()", arguments: [:], contentWorld: .page)
    }

    private func call(_ js: String, _ args: [String: Any] = [:]) {
        guard isReady else { return }
        webView.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { result in
            if case .failure(let error) = result { print("[editor] \(js) failed: \(error)") }
        }
    }

    // MARK: JS → Swift

    fileprivate func receive(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        #if DEBUG
        print("[bridge] ← \(type) \(msg["ms"] ?? msg["id"] ?? "")")
        #endif
        switch type {
        case "ready":
            isReady = true
            if !linkTargets.isEmpty { setLinkTargets(linkTargets) }
            if let pending = pendingLoad {
                pendingLoad = nil
                load(id: pending.id, text: pending.text)
            }
        case "changed":
            if let id = msg["id"] as? String, let text = msg["text"] as? String { onChanged?(id, text) }
        case "openLink":
            if let target = msg["target"] as? String { onOpenLink?(target) }
        case "openTag":
            if let tag = msg["tag"] as? String { onOpenTag?(tag) }
        case "metric":
            if msg["name"] as? String == "load", let ms = msg["ms"] as? Double { lastLoadMs = ms }
        default:
            break
        }
    }
}

/// WKUserContentController 會強引用 handler，用 proxy 斷開循環
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var host: WebEditorHost?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.receive(message.body) }
    }
}

// MARK: - SwiftUI 容器

#if os(iOS)
struct WebEditorContainer: UIViewRepresentable {
    let host: WebEditorHost
    func makeUIView(context: Context) -> WKWebView { host.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct WebEditorContainer: NSViewRepresentable {
    let host: WebEditorHost
    func makeNSView(context: Context) -> WKWebView { host.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

// MARK: - iOS 鍵盤上方的原生格式工具列

#if os(iOS)
/// 真正成為 first responder 的是 WKWebView 內部的 WKContentView，
/// 所以在執行期替它產生子類別並覆寫 inputAccessoryView。
final class EditorWebView: WKWebView {
    private static var installed = false
    fileprivate static let toolbar = makeToolbar()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !Self.installed else { return }
        installAccessory()
    }

    private func installAccessory() {
        guard let content = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let baseClass = object_getClass(content) else { return }

        let name = "EasyNotes_\(NSStringFromClass(baseClass))"
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let newClass = objc_allocateClassPair(baseClass, name, 0) {
            let selector = #selector(getter: UIResponder.inputAccessoryView)
            let block: @convention(block) (AnyObject) -> UIView? = { _ in EditorWebView.toolbar }
            if let method = class_getInstanceMethod(UIResponder.self, selector) {
                class_addMethod(newClass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
            }
            objc_registerClassPair(newClass)
            subclass = newClass
        }
        if let subclass {
            object_setClass(content, subclass)
            Self.installed = true
        }
    }

    private static func makeToolbar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        func item(_ symbol: String, _ command: String) -> UIBarButtonItem {
            UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in
                MainActor.assumeIsolated { WebEditorHost.shared.exec(command) }
            })
        }
        let dismiss = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction { _ in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        bar.items = [
            item("number", "heading"), item("bold", "bold"), item("italic", "italic"),
            item("list.bullet", "bullet"), item("checklist", "task"), item("link", "link"),
            item("chevron.left.forwardslash.chevron.right", "code"),
            .flexibleSpace(), dismiss,
        ]
        return bar
    }
}
#endif
