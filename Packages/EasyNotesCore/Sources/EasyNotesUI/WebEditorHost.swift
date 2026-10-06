import EasyNotesCore
import SwiftUI
import WebKit

/// The host shared by WebView plugins: preloads the page inside the plugin bundle and handles the Swift ⇄ JS Bridge.
/// Typing never goes through the Bridge; the JS side sends messages only when typing stops or on blur. The Bridge protocol is defined by each plugin.
@MainActor @Observable
public final class WebEditorHost {
    private static let log = DiagnosticsLog.logger("editor")
    public private(set) var isReady = false

    /// Created on first use, not in `init`: a host may be made inside `App.init`, before UIKit has set up event handling
    /// (see `EditorController.launched`). `prewarm()` creates it ahead of the first editor.
    public var webView: WKWebView {
        if let made { return made }
        let view = makeWebView()
        made = view
        return view
    }
    @ObservationIgnored private var made: WKWebView?
    @ObservationIgnored private let configuration: WKWebViewConfiguration
    @ObservationIgnored private let page: URL?
    /// Called after JS sends `ready` (pre-warming finished)
    @ObservationIgnored public var onReady: (() -> Void)?
    /// Other JS → Swift messages: the `type` and the whole message
    @ObservationIgnored public var onMessage: ((_ type: String, _ message: [String: Any]) -> Void)?
    @ObservationIgnored private let messageProxy = MessageProxy()
    @ObservationIgnored private let navigationPolicy = NavigationPolicy()

    /// The source of `vault://` images; set by the plugin in `EditorController.attach`
    @ObservationIgnored public var readResource: (@Sendable (_ path: String) async -> Data?)? {
        get { schemeHandler.read }
        set { schemeHandler.read = newValue }
    }
    /// The source of `embed://` embedded previews (`DocumentSession.embedImageReader`); set by the plugin in `attach`
    @ObservationIgnored public var readEmbed: (@Sendable (_ path: String) async -> Data?)? {
        get { embedHandler.read }
        set { embedHandler.read = newValue }
    }
    @ObservationIgnored private let schemeHandler = VaultSchemeHandler()
    @ObservationIgnored private let embedHandler = EmbedSchemeHandler()
    @ObservationIgnored private let symbolHandler = SymbolSchemeHandler()

    /// `page`: the HTML inside the plugin bundle; resources in the same folder are readable.
    /// `stylesheet`: CSS injected before the page loads (`ThemeCSS.stylesheet()`); light / dark switches by the page itself following the system, not through the Bridge
    public init(page: URL?, stylesheet: String? = nil) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(messageProxy, name: "bridge")
        config.setURLSchemeHandler(schemeHandler, forURLScheme: VaultSchemeHandler.scheme)
        config.setURLSchemeHandler(symbolHandler, forURLScheme: SymbolSchemeHandler.scheme)
        config.setURLSchemeHandler(embedHandler, forURLScheme: EmbedSchemeHandler.scheme)
        // The UI language is injected once, read by `locale` in web/src/shared/i18n.ts; not through the Bridge and not on the typing path
        let language = Bundle.main.preferredLocalizations.first ?? "zh-Hant"
        let languageLiteral = String(decoding: (try? JSONEncoder().encode(language)) ?? Data("\"zh-Hant\"".utf8), as: UTF8.self)
        config.userContentController.addUserScript(
            WKUserScript(source: "window.__locale=\(languageLiteral);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let stylesheet {
            let literal = String(decoding: (try? JSONEncoder().encode(stylesheet)) ?? Data("\"\"".utf8), as: UTF8.self)
            let source = "{const s=document.createElement('style');s.id='theme';s.textContent=\(literal);document.documentElement.appendChild(s);}"
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration = config
        self.page = page
        messageProxy.host = self
        navigationPolicy.pageURL = page
    }

    /// Creates the WebView and starts loading the page, so the first editor opens without waiting
    public func prewarm() {
        _ = webView
    }

    private func makeWebView() -> WKWebView {
        let webView: WKWebView
        #if os(iOS)
        let editorView = EditorWebView(frame: .zero, configuration: configuration)
        editorView.accessory = makeInputAccessory?()
        webView = editorView
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // Scrolling is left to the page's own scroller to avoid two levels of scrolling
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        #if DEBUG
        webView.isInspectable = true // Safari → Develop → the WebView can be inspected; off in Release so external programs cannot attach to the WebView
        #endif
        webView.navigationDelegate = navigationPolicy

        if let page {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            assertionFailure("Editor bundle missing; run `npm run build` in web/")
        }
        return webView
    }

    #if os(iOS)
    /// Makes the native toolbar above the keyboard; called when the WebView is created (the toolbar is a platform view too)
    @ObservationIgnored public var makeInputAccessory: (() -> UIView?)?
    #endif

    // MARK: Swift → JS

    /// Not sent before the page is ready; state that needs resending is handled by the plugin in `onReady`
    public func call(_ js: String, _ args: [String: Any] = [:]) {
        guard isReady else { return }
        webView.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                // `js` is the app's own script, `args` (which may hold note text) is never logged
                Self.log.error("editor script failed: \(js, privacy: .public) \(DiagnosticsLog.describe(error), privacy: .public)")
            }
        }
    }

    /// Waits for JS to finish, for example flush
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

/// The WebView may stay only on that one page inside the plugin bundle: any navigation (link, form, `location`) is cancelled.
/// An http(s) / mailto link the user clicked is opened by the system instead (security.md invariant 4)
enum NavigationDecision: Equatable {
    case allow, cancel, openExternally

    static func decide(url: URL?, pageURL: URL?, isLinkActivation: Bool) -> NavigationDecision {
        guard let url else { return .cancel }
        if !isLinkActivation, let pageURL, url.isFileURL, url.standardizedFileURL.path == pageURL.standardizedFileURL.path {
            return .allow // Loading the editor page itself (including reload)
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
                // On iOS open is async: it does not block the navigation decision and `.cancel` returns immediately
                Task { @MainActor in await UIApplication.shared.open(url) }
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
            return .cancel
        }
    }
}

/// WKUserContentController holds a strong reference to the handler; a proxy breaks the cycle
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var host: WebEditorHost?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.receive(message.body) }
    }
}

// MARK: - SwiftUI container

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

// MARK: - The native toolbar above the iOS keyboard

#if os(iOS)
nonisolated(unsafe) private var accessoryKey: UInt8 = 0

/// What actually becomes first responder is the WKContentView inside the WKWebView,
/// so a subclass is created for it at run time with inputAccessoryView overridden. The toolbar is stored on each content view,
/// so several WebView plugins can have different toolbars.
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
