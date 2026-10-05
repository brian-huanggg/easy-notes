import Foundation
import Testing
@testable import EasyNotesCore

/// `#bundle` crashes outright if the module's resource bundle is not found; with no translation it must return the source language (the key itself)
struct LocalizationTests {
    @Test func helperResolvesToSourceLanguage() {
        #expect(L("測試") == "測試")
        #expect(L("\(3) 個項目") == "3 個項目")
    }
}
