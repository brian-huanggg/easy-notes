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
    /// `[[` 自動完成的候選清單
    func linkTargetsChanged(_ names: [String])
}

extension EditorController {
    public func attach(_ session: any DocumentSession) {}
    public func flush() async {}
    public func externalChange(path: String, data: Data) {}
    public func close(path: String) {}
    public func linkTargetsChanged(_ names: [String]) {}
}

extension EnvironmentValues {
    @Entry public var documentSession: (any DocumentSession)? = nil
}
