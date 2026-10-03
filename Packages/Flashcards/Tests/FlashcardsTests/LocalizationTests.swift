import Foundation
import Testing
@testable import Flashcards

/// `#bundle` 找不到模組的資源 bundle 會直接 crash；沒有翻譯時要回傳來源語言（key 本身）
struct LocalizationTests {
    @Test func helperResolvesToSourceLanguage() {
        #expect(L("測試") == "測試")
        #expect(L("\(3) 個項目") == "3 個項目")
    }
}
