import Testing
@testable import EasyNotesCore

struct AttachmentsTests {
    @Test func legacyPathMapsOnlyAttachmentsFolder() {
        #expect(Attachments.legacyPath(for: "Attachments/a.png") == "附件/a.png")
        #expect(Attachments.legacyPath(for: "Attachments/sub/b.pdf") == "附件/sub/b.pdf")
        #expect(Attachments.legacyPath(for: "附件/a.png") == nil)
        #expect(Attachments.legacyPath(for: "Notes/Attachments/a.png") == nil)
        #expect(Attachments.legacyPath(for: "Attachments/") == nil)
        #expect(Attachments.legacyPath(for: "AttachmentsX/a.png") == nil)
    }
}
