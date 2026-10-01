import EasyNotesUI
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// 全 App 共用一個預先載入的 CodeMirror 6 WebView。
/// 切換筆記只呼叫 `editor.load`，不重新載入頁面；打字不經過 Bridge，
/// JS 端在停止輸入 300ms 或失焦時才回報 `changed`。
@MainActor @Observable
public final class MarkdownEditor: EditorController {
    public static let shared = MarkdownEditor()

    /// Spike S1 量測：JS 端切換文件耗時（ms）
    public private(set) var lastLoadMs: Double?

    @ObservationIgnored let host: WebEditorHost
    @ObservationIgnored private weak var session: (any DocumentSession)?
    @ObservationIgnored private var pendingLoad: (id: String, text: String)?
    @ObservationIgnored private var linkTargets: [String] = []

    private init() {
        host = WebEditorHost(page: Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
        #if os(iOS)
        host.inputAccessoryView = Self.makeToolbar()
        #endif
        host.onReady = { [weak self] in self?.ready() }
        host.onMessage = { [weak self] type, msg in self?.receive(type, msg) }
    }

    // MARK: Swift → JS

    func load(id: String, text: String) {
        guard host.isReady else {
            pendingLoad = (id, text)
            return
        }
        host.call("editor.load(id, text)", ["id": id, "text": text])
    }

    func exec(_ command: String) {
        host.call("editor.exec(command)", ["command": command])
    }

    func focus() {
        host.call("editor.focus()")
    }

    func benchmark(lines: Int) {
        host.call("editor.benchmark(lines)", ["lines": lines])
    }

    // MARK: EditorController

    public func attach(_ session: any DocumentSession) {
        self.session = session
    }

    public func flush() async {
        await host.callAndWait("editor.flush()")
    }

    /// 外部修改（Finder、其他編輯器、同步）後更新編輯器內容，保留游標與 undo
    public func externalChange(path: String, data: Data) {
        guard Self.handles(path) else { return }
        host.call("editor.applyRemote(id, text)", ["id": path, "text": String(decoding: data, as: UTF8.self)])
    }

    public func close(path: String) {
        guard Self.handles(path) else { return }
        host.call("editor.close(id)", ["id": path])
    }

    public func linkTargetsChanged(_ names: [String]) {
        linkTargets = names
        host.call("editor.setLinkTargets(names)", ["names": names])
    }

    private static func handles(_ path: String) -> Bool {
        MarkdownKind.fileExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: JS → Swift

    private func ready() {
        if !linkTargets.isEmpty { linkTargetsChanged(linkTargets) }
        if let pending = pendingLoad {
            pendingLoad = nil
            load(id: pending.id, text: pending.text)
        }
    }

    private func receive(_ type: String, _ msg: [String: Any]) {
        switch type {
        case "changed":
            if let id = msg["id"] as? String, let text = msg["text"] as? String {
                session?.write(Data(text.utf8), to: id)
            }
        case "openLink":
            if let target = msg["target"] as? String { session?.openLink(target) }
        case "openTag":
            if let tag = msg["tag"] as? String { session?.search("#" + tag) }
        case "metric":
            if msg["name"] as? String == "load", let ms = msg["ms"] as? Double { lastLoadMs = ms }
        default:
            break
        }
    }

    // MARK: iOS 鍵盤上方的原生格式工具列

    #if os(iOS)
    private static func makeToolbar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        func item(_ symbol: String, _ command: String) -> UIBarButtonItem {
            UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in
                MainActor.assumeIsolated { MarkdownEditor.shared.exec(command) }
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
    #endif
}
