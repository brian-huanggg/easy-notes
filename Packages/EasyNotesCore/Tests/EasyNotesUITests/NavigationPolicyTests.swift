import Foundation
import Testing
@testable import EasyNotesUI

/// WebView 不能被導覽到別處（security.md 不變條件 4）
struct NavigationPolicyTests {
    let page = URL(filePath: "/App/Editor/index.html")

    @Test func onlyTheEditorPageItselfLoads() {
        #expect(NavigationDecision.decide(url: page, pageURL: page, isLinkActivation: false) == .allow)
        #expect(NavigationDecision.decide(url: URL(filePath: "/App/Editor/../Editor/index.html"), pageURL: page, isLinkActivation: false) == .allow)
        #expect(NavigationDecision.decide(url: URL(filePath: "/etc/passwd"), pageURL: page, isLinkActivation: false) == .cancel)
        #expect(NavigationDecision.decide(url: URL(string: "https://evil.example")!, pageURL: page, isLinkActivation: false) == .cancel)
        #expect(NavigationDecision.decide(url: URL(string: "vault://a.png")!, pageURL: page, isLinkActivation: false) == .cancel)
        #expect(NavigationDecision.decide(url: nil, pageURL: page, isLinkActivation: false) == .cancel)
    }

    @Test func clickedLinksLeaveToTheSystem() {
        #expect(NavigationDecision.decide(url: URL(string: "https://example.com")!, pageURL: page, isLinkActivation: true) == .openExternally)
        #expect(NavigationDecision.decide(url: URL(string: "mailto:a@b.c")!, pageURL: page, isLinkActivation: true) == .openExternally)
        #expect(NavigationDecision.decide(url: URL(string: "javascript:alert(1)")!, pageURL: page, isLinkActivation: true) == .cancel)
        #expect(NavigationDecision.decide(url: URL(string: "file:///etc/passwd")!, pageURL: page, isLinkActivation: true) == .cancel)
        #expect(NavigationDecision.decide(url: page, pageURL: page, isLinkActivation: true) == .cancel)
    }
}
