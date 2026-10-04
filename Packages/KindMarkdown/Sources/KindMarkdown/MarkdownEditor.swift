import EasyNotesCore
import EasyNotesUI
import Foundation
import Observation
#if os(iOS)
import SwiftUI
import UIKit
#else
import AppKit
#endif

/// 全 App 共用一個預先載入的 CodeMirror 6 WebView。
/// 切換筆記只呼叫 `editor.load`，不重新載入頁面；打字不經過 Bridge，
/// JS 端在停止輸入 300ms 或失焦時才回報 `changed`。
@MainActor @Observable
public final class MarkdownEditor: EditorController {
    public static let shared = MarkdownEditor()

    /// 文件頭、格式工具列要求的原生選擇介面；由 MarkdownEditorView 呈現
    enum Picker: Equatable {
        /// 封面選單（選擇圖片、移除）
        case cover(hasCover: Bool)
        /// 選擇封面圖片的檔案面板
        case coverFile
        case icon(current: String?)
        /// 格式工具列的插入圖片
        case image
    }

    /// Spike S1 量測：JS 端切換文件耗時（ms）
    public private(set) var lastLoadMs: Double?
    var picker: Picker?

    @ObservationIgnored let host: WebEditorHost
    @ObservationIgnored private weak var session: (any DocumentSession)?
    @ObservationIgnored private var pendingLoad: (id: String, text: String, modified: Date?)?
    @ObservationIgnored private var linkTargets: [[String: Any]] = []
    @ObservationIgnored private var currentPath: String?
    /// 這個編輯器載入過的文件：`changed` 只接受這些 id（JS 端不能自己指定要寫哪個檔案）
    @ObservationIgnored private var loadedPaths = Set<String>()
    /// `reveal` 在檔案載入前就送來：載入後再捲動
    @ObservationIgnored private var pendingReveal: (path: String, line: Int)?
    /// 記憶體壓力來源（macOS）；iOS 用 UIApplication 的記憶體警告通知
    @ObservationIgnored private var memorySource: DispatchSourceMemoryPressure?
    #if os(iOS)
    /// 保留 hosting controller：只留 view 時 SwiftUI 不會更新
    @ObservationIgnored private var keyboardBar: UIViewController?
    #endif

    private init() {
        host = WebEditorHost(page: Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Editor"),
                             stylesheet: ThemeCSS.stylesheet())
        host.onReady = { [weak self] in self?.ready() }
        host.onMessage = { [weak self] type, msg in self?.receive(type, msg) }
        #if os(iOS)
        let bar = Self.makeKeyboardBar(self)
        keyboardBar = bar
        host.inputAccessoryView = bar.view
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trimStates() }
        }
        #else
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.trimStates() } }
        source.resume()
        memorySource = source
        #endif
    }

    /// 記憶體警告：丟掉不在畫面上的 `EditorState`（再開時以磁碟內容重建，只少了 undo 紀錄）
    func trimStates() {
        host.call("editor.trim()", [:])
    }

    // MARK: Swift → JS

    func load(id: String, text: String, modified: Date?) {
        currentPath = id
        loadedPaths.insert(id)
        guard host.isReady else {
            pendingLoad = (id, text, modified)
            return
        }
        host.call("editor.load(id, text, meta)", ["id": id, "text": text, "meta": Self.meta(modified)])
        if let reveal = pendingReveal, reveal.path == id {
            pendingReveal = nil
            host.call("editor.revealLine(id, line)", ["id": id, "line": reveal.line])
        }
    }

    func exec(_ command: String, _ arg: String? = nil) {
        host.call("editor.exec(command, arg)", ["command": command, "arg": arg ?? NSNull()])
    }

    /// 設定或移除 frontmatter 欄位（封面、icon）。在 JS 端以一般編輯套用：可以 undo，停止輸入後照常寫回檔案
    func setFrontmatter(_ key: String, _ value: String?) {
        host.call("editor.setFrontmatter(key, value)", ["key": key, "value": value ?? NSNull()])
    }

    /// 選好的封面圖片：Vault 外的檔案先複製到附件資料夾
    func chooseCover(_ url: URL) async {
        guard let path = await session?.importAttachment(url) else { return }
        setFrontmatter("cover", path)
    }

    /// 剪貼簿是否有圖片（封面選單用來決定「貼上」是否可用）
    static var clipboardHasImage: Bool {
        #if os(iOS)
        UIPasteboard.general.hasImages
        #else
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        #endif
    }

    /// 把剪貼簿的圖片存成暫存 PNG 當封面（⌘V）；`chooseCover` 會再複製到附件資料夾
    @discardableResult
    func pasteCover() async -> Bool {
        #if os(iOS)
        let png = UIPasteboard.general.image?.pngData()
        #else
        let png = (NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage)
            .flatMap { $0.tiffRepresentation }
            .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        #endif
        guard let png else { return false }
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(L("貼上的圖片-\(stamp).png"))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch { return false }
        defer { try? FileManager.default.removeItem(at: dir) }
        await chooseCover(url)
        return true
    }

    /// 格式工具列的插入圖片：`![[Attachments/x.png]]` 獨占一行
    func insertImage(_ url: URL) async {
        guard let path = await session?.importAttachment(url) else { return }
        exec("insertText", "![[\(path)]]")
    }

    /// 浮動格式工具列與 iOS 鍵盤工具列共用的按鈕
    var formatItems: [ToolItem] {
        [
            ToolItem("textformat", help: L("文字樣式"), menu: [
                ToolItem("text.alignleft", help: L("內文")) { self.exec("paragraph") },
                ToolItem("1.square", help: L("標題 1")) { self.exec("heading1") },
                ToolItem("2.square", help: L("標題 2")) { self.exec("heading2") },
                ToolItem("3.square", help: L("標題 3")) { self.exec("heading3") },
            ]),
            ToolItem("checklist", help: L("待辦事項")) { self.exec("task") },
            ToolItem("photo", help: L("插入圖片")) { self.picker = .image },
            ToolItem("tablecells", help: L("插入表格")) { self.exec("table") },
        ]
    }

    private static func meta(_ modified: Date?) -> [String: Any] {
        ["modified": modified.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull()]
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
        host.readResource = session.resourceReader
        host.readEmbed = session.embedImageReader
    }

    public func flush() async {
        await host.callAndWait("editor.flush()")
    }

    /// 外部修改（Finder、其他編輯器、同步）後更新編輯器內容，保留游標與 undo
    public func externalChange(path: String, data: Data) {
        guard Self.handles(path) else { return }
        host.call("editor.applyRemote(id, text)", ["id": path, "text": String(decoding: data, as: UTF8.self)])
        host.call("editor.setMeta(id, meta)", ["id": path, "meta": Self.meta(session?.modified(path))])
    }

    public func reveal(path: String, line: Int) {
        guard Self.handles(path) else { return }
        if currentPath == path, host.isReady, pendingLoad == nil {
            host.call("editor.revealLine(id, line)", ["id": path, "line": line])
        } else {
            pendingReveal = (path, line)
        }
    }

    public func close(path: String) {
        guard Self.handles(path) else { return }
        host.call("editor.close(id)", ["id": path])
    }

    /// 連結卡片需要類型圖示：WebView 沒有 SF Symbols，畫成 PNG 後當 CSS mask，顏色由 CSS 依深淺色決定
    public func linkTargetsChanged(_ targets: [LinkTarget]) {
        linkTargets = targets.map { target in
            var item: [String: Any] = [
                "name": target.name,
                "path": target.path,
                "tint": [target.tint.base.light, target.tint.base.dark, target.tint.soft.light, target.tint.soft.dark],
                "modified": target.modified.timeIntervalSince1970 * 1000,
            ]
            if let icon = SymbolImage.pngDataURI(target.symbol) { item["icon"] = icon }
            if let summary = target.summary { item["summary"] = summary }
            if let hash = target.hash { item["hash"] = hash }
            return item
        }
        host.call("editor.setLinkTargets(targets)", ["targets": linkTargets])
    }

    private static func handles(_ path: String) -> Bool {
        MarkdownKind.fileExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: JS → Swift

    private func ready() {
        if !linkTargets.isEmpty { host.call("editor.setLinkTargets(targets)", ["targets": linkTargets]) }
        if let pending = pendingLoad {
            pendingLoad = nil
            load(id: pending.id, text: pending.text, modified: pending.modified)
        }
    }

    /// Bridge 傳來的 `changed` 是否可以寫入：必須是這個編輯器載入過、且在 Vault 內的相對路徑
    static func acceptsChange(id: String, loaded: Set<String>) -> Bool {
        loaded.contains(id) && VaultFS.isSafe(path: id)
    }

    private func receive(_ type: String, _ msg: [String: Any]) {
        switch type {
        case "changed":
            if let id = msg["id"] as? String, let text = msg["text"] as? String,
               Self.acceptsChange(id: id, loaded: loadedPaths) {
                session?.write(Data(text.utf8), to: id)
            }
        case "openLink":
            if let target = msg["target"] as? String { session?.openLink(target) }
        case "openTag":
            if let tag = msg["tag"] as? String { session?.search("#" + tag) }
        case "pickCover":
            picker = .cover(hasCover: msg["hasCover"] as? Bool ?? false)
        case "pickIcon":
            picker = .icon(current: msg["icon"] as? String)
        case "metric":
            if msg["name"] as? String == "load", let ms = msg["ms"] as? Double { lastLoadMs = ms }
        default:
            break
        }
    }

    // MARK: iOS 鍵盤上方的原生格式工具列（設計稿的 Format Bar）

    #if os(iOS)
    private static func makeKeyboardBar(_ editor: MarkdownEditor) -> UIViewController {
        let bar = FormatBar(editor.formatItems, style: .keyboard, dismiss: ToolItem("keyboard.chevron.compact.down", help: L("收起鍵盤")) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        let host = UIHostingController(rootView: bar)
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 60)
        host.view.autoresizingMask = .flexibleWidth
        return host
    }
    #endif
}
