import Foundation

/// 外掛從檔案內容抽出的一筆索引資料。`value` 由外掛自訂（通常是 JSON），Core 只存不解讀。
public struct IndexRecord: Equatable, Sendable {
    /// 在同一個檔案、同一個 contributor 內唯一
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// 外掛的索引擴充點（例如 Flashcards 從 md 抽出卡片）。索引時對每個檔案呼叫，結果存在通用的 records 表。
public protocol IndexContributor: Sendable {
    /// records 的命名空間，所有外掛間不可重複
    var id: String { get }
    /// 抽取規則改變時加一：索引會整個重建
    var version: Int { get }
    func records(path: String, kindID: String, data: Data) -> [IndexRecord]
}

/// 外掛在背景改寫檔案內容（例如 Flashcards 替卡片補上 `^id`）。
/// App 只對本機產生的變動、且不在編輯中的檔案呼叫；回傳 nil 代表不需要改。
public protocol ContentFixer: Sendable {
    func fix(path: String, kindID: String, data: Data, index: VaultIndex) async -> Data?
}
