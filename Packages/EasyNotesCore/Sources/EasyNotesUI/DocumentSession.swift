import Foundation
import SwiftUI

/// 外掛編輯器存取 Vault 的唯一入口，由 App 實作。外掛不 import App，也不直接碰網路。
@MainActor
public protocol DocumentSession: AnyObject {
    func readData(_ path: String) -> Data
    /// 寫入在背景進行，寫完更新索引與同步佇列
    func write(_ data: Data, to path: String)
    /// `[[連結]]`：找到就開啟，找不到就建立
    func openLink(_ target: String)
    /// 在側邊欄顯示搜尋結果，例如點擊 #標籤
    func search(_ query: String)
    /// 最後修改時間（文件頭的「N 分鐘前編輯」）
    func modified(_ path: String) -> Date?
    /// 把 Vault 外的檔案（例如封面圖片）複製到 Vault 的附件資料夾，回傳 Vault 內路徑；
    /// 已在 Vault 內的檔案直接回傳它的路徑
    func importAttachment(_ url: URL) async -> String?
    /// 背景讀取 Vault 內的檔案，給 WebView 的 `vault://` 圖片使用；不在主執行緒做 I/O
    var resourceReader: @Sendable (_ path: String) async -> Data? { get }
}

extension DocumentSession {
    public func readText(_ path: String) -> String {
        String(decoding: readData(path), as: UTF8.self)
    }
}

/// App 透過它通知常駐的編輯器（例如共用的 WebView），不必知道編輯器的實作。
/// 預設實作都不做事，外掛只覆寫需要的。
@MainActor
public protocol EditorController: AnyObject {
    /// App 建立 DocumentSession 後呼叫一次
    func attach(_ session: any DocumentSession)
    /// 把尚未寫回的變更送出；改名、刪除、進入背景前呼叫
    func flush() async
    /// 檔案被外部工具或同步修改
    func externalChange(path: String, data: Data)
    /// 檔案被改名或刪除，丟掉保留的編輯狀態
    func close(path: String)
    /// `[[` 自動完成的候選清單與連結卡片的資料
    func linkTargetsChanged(_ targets: [LinkTarget])
}

extension EditorController {
    public func attach(_ session: any DocumentSession) {}
    public func flush() async {}
    public func externalChange(path: String, data: Data) {}
    public func close(path: String) {}
    public func linkTargetsChanged(_ targets: [LinkTarget]) {}
}

/// `[[連結]]` 的目標：名稱（不含副檔名）與連結卡片顯示的類型、摘要、時間。
/// 類型的圖示與顏色由 App 從 PluginRegistry 取得，編輯器不認識其他外掛。
public struct LinkTarget: Hashable, Sendable {
    public let name: String
    public let path: String
    /// Registry 中該類型的 SF Symbol
    public let symbol: String
    public let tint: KindTint
    /// 外掛提供的一行摘要（「320 個字」「24 列」）
    public let summary: String?
    public let modified: Date

    public init(name: String, path: String, symbol: String, tint: KindTint, summary: String?, modified: Date) {
        self.name = name
        self.path = path
        self.symbol = symbol
        self.tint = tint
        self.summary = summary
        self.modified = modified
    }
}

extension EnvironmentValues {
    @Entry public var documentSession: (any DocumentSession)? = nil
}
