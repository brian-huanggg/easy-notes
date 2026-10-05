import SwiftUI
import WebKit

/// WebView 外掛共用的宿主：預先載入外掛 bundle 內的頁面，處理 Swift ⇄ JS Bridge。
/// 打字不經過 Bridge；JS 端在停止輸入或失焦時才送訊息。Bridge 協定由各外掛自行定義。
@MainActor @Observable
public final class WebEditorHost {
    public private(set) var isReady = false

    @ObservationIgnored public let webView: WKWebView
    /// JS 送出 `ready` 後呼叫（預熱完成）
    @ObservationIgnored public var onReady: (() -> Void)?
    /// 其他 JS → Swift 訊息：`type` 與整個訊息
    @ObservationIgnored public var onMessage: ((_ type: String, _ message: [String: Any]) -> Void)?
    @ObservationIgnored private let messageProxy = MessageProxy()
    @ObservationIgnored private let navigationPolicy = NavigationPolicy()

    /// `vault://` 圖片的來源；由外掛在 `EditorController.attach` 時設定
    @ObservationIgnored public var readResource: (@Sendable (_ path: String) async -> Data?)? {
        get { schemeHandler.read }
        set { schemeHandler.read = newValue }
    }
    /// `embed://` 嵌入預覽的來源（`DocumentSession.embedImageReader`）；由外掛在 `attach` 時設定
    @ObservationIgnored public var readEmbed: (@Sendable (_ path: String) async -> Data?)? {
        get { embedHandler.read }
        set { embedHandler.read = newValue }
    }
    @ObservationIgnored private let schemeHandler = VaultSchemeHandler()
    @ObservationIgnored private let embedHandler = EmbedSchemeHandler()
    @ObservationIgnored private let symbolHandler = SymbolSchemeHandler()

    /// `page`：外掛 bundle 內的 HTML，同資料夾的資源都可讀取。
    /// `stylesheet`：頁面載入前注入的 CSS（`ThemeCSS.stylesheet()`），深淺色由頁面自己依系統切換，不經 Bridge
    public init(page: URL?, stylesheet: String? = nil) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(messageProxy, name: "bridge")
        config.setURLSchemeHandler(schemeHandler, forURLScheme: VaultSchemeHandler.scheme)
        config.setURLSchemeHandler(symbolHandler, forURLScheme: SymbolSchemeHandler.scheme)
        config.setURLSchemeHandler(embedHandler, forURLScheme: EmbedSchemeHandler.scheme)
        // 介面語言一次性注入，web/src/shared/i18n.ts 的 `locale` 讀它；不經 Bridge，也不在打字路徑上
        let language = Bundle.main.preferredLocalizations.first ?? "zh-Hant"
        let languageLiteral = String(decoding: (try? JSONEncoder().encode(language)) ?? Data("\"zh-Hant\"".utf8), as: UTF8.self)
        config.userContentController.addUserScript(
            WKUserScript(source: "window.__locale=\(languageLiteral);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let stylesheet {
            let literal = String(decoding: (try? JSONEncoder().encode(stylesheet)) ?? Data("\"\"".utf8), as: UTF8.self)
            let source = "{const s=document.createElement('style');s.id='theme';s.textContent=\(literal);document.documentElement.appendChild(s);}"
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        #if os(iOS)
        webView = EditorWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // 捲動交給頁面自己的 scroller，避免兩層捲動
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        #if DEBUG
        webView.isInspectable = true // Safari → 開發 → 可檢查 WebView；Release 不開，避免外部程式附加到 WebView
        #endif
        messageProxy.host = self
        navigationPolicy.pageURL = page
        webView.navigationDelegate = navigationPolicy

        if let page {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            assertionFailure("Editor bundle missing; run `npm run build` in web/")
        }
    }

    #if os(iOS)
    /// 鍵盤上方的原生工具列
    public var inputAccessoryView: UIView? {
        get { (webView as? EditorWebView)?.accessory }
        set { (webView as? EditorWebView)?.accessory = newValue }
    }
    #endif

    // MARK: Swift → JS

    /// 頁面尚未 ready 時不送出；需要補送的狀態由外掛在 `onReady` 處理
    public func call(_ js: String, _ args: [String: Any] = [:]) {
        guard isReady else { return }
        webView.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { result in
            if case .failure(let error) = result { print("[editor] \(js) failed: \(error)") }
        }
    }

    /// 等 JS 執行完成，例如 flush
    public func callAndWait(_ js: String) async {
        guard isReady else { return }
        _ = try? await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
    }

    // MARK: JS → Swift

    fileprivate func receive(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        #if DEBUG
        print("[bridge] ← \(type) \(msg["ms"] ?? msg["id"] ?? "")")
        #endif
        if type == "ready" {
            isReady = true
            onReady?()
        } else {
            onMessage?(type, msg)
        }
    }
}

/// WebView 只能停在外掛 bundle 內的那一頁：任何導覽（連結、表單、`location`）都取消。
/// 使用者點的 http(s) / mailto 連結改由系統開啟（security.md 不變條件 4）
enum NavigationDecision: Equatable {
    case allow, cancel, openExternally

    static func decide(url: URL?, pageURL: URL?, isLinkActivation: Bool) -> NavigationDecision {
        guard let url else { return .cancel }
        if !isLinkActivation, let pageURL, url.isFileURL, url.standardizedFileURL.path == pageURL.standardizedFileURL.path {
            return .allow // 載入編輯器頁面本身（含 reload）
        }
        if isLinkActivation, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .openExternally }
        return .cancel
    }
}

private final class NavigationPolicy: NSObject, WKNavigationDelegate {
    var pageURL: URL?

    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let decision = NavigationDecision.decide(url: action.request.url, pageURL: pageURL,
                                                 isLinkActivation: action.navigationType == .linkActivated)
        switch decision {
        case .allow: return .allow
        case .cancel: return .cancel
        case .openExternally:
            if let url = action.request.url {
                #if os(iOS)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
            return .cancel
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
public struct WebEditorContainer: UIViewRepresentable {
    let host: WebEditorHost
    public init(host: WebEditorHost) { self.host = host }
    public func makeUIView(context: Context) -> WKWebView { host.webView }
    public func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
public struct WebEditorContainer: NSViewRepresentable {
    let host: WebEditorHost
    public init(host: WebEditorHost) { self.host = host }
    public func makeNSView(context: Context) -> WKWebView { host.webView }
    public func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

// MARK: - iOS 鍵盤上方的原生工具列

#if os(iOS)
nonisolated(unsafe) private var accessoryKey: UInt8 = 0

/// 真正成為 first responder 的是 WKWebView 內部的 WKContentView，
/// 所以在執行期替它產生子類別並覆寫 inputAccessoryView。工具列存在各 content view 上，
/// 多個 WebView 外掛可以有不同的工具列。
final class EditorWebView: WKWebView {
    var accessory: UIView? {
        didSet { installAccessory() }
    }
    private var installed = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { installAccessory() }
    }

    private func installAccessory() {
        guard let accessory, let content = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }) else { return }
        objc_setAssociatedObject(content, &accessoryKey, accessory, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard !installed, let baseClass = object_getClass(content) else { return }

        let name = "EasyNotes_\(NSStringFromClass(baseClass))"
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let newClass = objc_allocateClassPair(baseClass, name, 0) {
            let selector = #selector(getter: UIResponder.inputAccessoryView)
            let block: @convention(block) (AnyObject) -> UIView? = { view in
                objc_getAssociatedObject(view, &accessoryKey) as? UIView
            }
            if let method = class_getInstanceMethod(UIResponder.self, selector) {
                class_addMethod(newClass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
            }
            objc_registerClassPair(newClass)
            subclass = newClass
        }
        if let subclass {
            object_setClass(content, subclass)
            installed = true
        }
    }
}
#endif
