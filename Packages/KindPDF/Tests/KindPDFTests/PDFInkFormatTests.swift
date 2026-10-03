import EasyNotesCore
import ExcalidrawKit
import Foundation
import Testing
@testable import KindPDF

/// 5a：`.pdf.ink` 讀寫與依頁合併
struct PDFInkFormatTests {
    @Test func emptyInkSerializesHeaderOnly() throws {
        let json = try #require(JSONSerialization.jsonObject(with: PDFInk(pdfHash: "h").data()) as? [String: Any])
        #expect(json["type"] as? String == "easynotes-pdf-ink")
        #expect(json["version"] as? Int == 1)
        #expect(json["pdfHash"] as? String == "h")
        #expect((json["pages"] as? [String: Any])?.isEmpty == true)
        #expect(try PDFInk(data: Data()).pageIndexes.isEmpty)
        #expect(try PDFInk(data: PDFInkKind.template(title: "x")).pdfHash == "")
    }

    @Test func rejectsOtherFormats() {
        #expect(throws: (any Error).self) { try PDFInk(data: Data(#"{"type":"excalidraw"}"#.utf8)) }
        #expect(throws: (any Error).self) { try PDFInk(data: Data("not json".utf8)) }
    }

    @Test func strokesRoundTripPerPage() throws {
        let marker = Sample.stroke(x: 100, ink: "com.apple.ink.marker", opacity: 0.5)
        let ink = Sample.ink(page: 4, strokes: [Sample.stroke(), marker])
        let loaded = try PDFInk(data: ink.data())

        #expect(loaded.pageIndexes == [4])
        #expect(loaded.elements(page: 0).isEmpty)
        let strokes = loaded.scene(page: 4).inkStrokes
        #expect(strokes.count == 2)
        #expect(strokes[0].matches(Sample.stroke()))
        // 螢光筆：ink 類型與透明度保留
        #expect(strokes[1].ink == "com.apple.ink.marker")
        #expect(strokes[1].opacity == 0.5)
        let raw = try #require(JSONSerialization.jsonObject(with: ink.data()) as? [String: Any])
        #expect(Set((raw["pages"] as? [String: Any] ?? [:]).keys) == ["4"])
    }

    @Test func unknownFieldsArePreserved() throws {
        let json = """
            {"type":"easynotes-pdf-ink","version":1,"pdfHash":"h","future":{"a":1},
             "pages":{"2":{"elements":[{"id":"x","type":"magic","version":3,"custom":true}],"note":"keep"}},
             "files":{}}
            """
        var ink = try PDFInk(data: Data(json.utf8))
        ink.pdfHash = "h2"
        let out = try #require(JSONSerialization.jsonObject(with: ink.data()) as? [String: Any])
        #expect((out["future"] as? [String: Any])?["a"] as? Int == 1)
        let page = try #require((out["pages"] as? [String: Any])?["2"] as? [String: Any])
        #expect(page["note"] as? String == "keep")
        #expect(((page["elements"] as? [[String: Any]])?.first?["custom"]) as? Bool == true)
        #expect(out["pdfHash"] as? String == "h2")
    }

    @Test func pageWithoutElementsIsRemoved() {
        var ink = Sample.ink(page: 1, strokes: [Sample.stroke()])
        ink.setElements([], page: 1)
        #expect(ink.pageIndexes.isEmpty)
        #expect(ink.isEmpty)
    }

    @Test func erasingLeavesTombstone() {
        var ink = Sample.ink(page: 0, strokes: [Sample.stroke()])
        var scene = ink.scene(page: 0)
        scene.replaceInk(with: [])
        ink.setScene(scene, page: 0)
        #expect(ink.pageIndexes == [0]) // 墓碑留著，合併才知道被刪了
        #expect(ink.isEmpty)
        #expect(ink.elements(page: 0).first?["isDeleted"] as? Bool == true)
    }

    @Test func pdfHashIsSHA256() {
        #expect(PDFInk.hash(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(PDFInk.path(forPDF: "課程/講義.pdf") == "課程/講義.pdf.ink")
    }

    // MARK: 合併

    @Test func differentPagesAreBothKept() throws {
        let base = PDFInk(pdfHash: "abc")
        let local = Sample.ink(page: 0, strokes: [Sample.stroke()], into: base)
        let remote = Sample.ink(page: 7, strokes: [Sample.stroke(x: 50)], into: base)
        let data = try #require(PDFInkKind.merge(base: base.data(), local: local.data(), remote: remote.data()))
        let merged = try PDFInk(data: data)
        #expect(merged.pageIndexes == [0, 7])
        #expect(merged.scene(page: 7).inkStrokes.count == 1)
    }

    @Test func samePageMergesByElement() {
        let base = Sample.ink(page: 2, strokes: [Sample.stroke(), Sample.stroke(x: 30)])
        // 本機加一筆、遠端擦掉第一筆
        let local = Sample.ink(page: 2, strokes: [Sample.stroke(x: 200)], into: base)
        var remote = base
        var scene = remote.scene(page: 2)
        scene.replaceInk(with: [scene.inkStrokes[1]])
        remote.setScene(scene, page: 2)

        let merged = PDFInk.merge(local: local, remote: remote)
        #expect(merged.scene(page: 2).inkStrokes.count == 2)
        #expect(PDFInk.merge(local: remote, remote: local).scene(page: 2).inkStrokes.count == 2)
    }

    @Test func localPDFHashWins() {
        let local = Sample.ink(page: 0, strokes: [], into: PDFInk(pdfHash: "local"))
        let remote = PDFInk(pdfHash: "remote")
        #expect(PDFInk.merge(local: local, remote: remote).pdfHash == "local")
        #expect(PDFInk.merge(local: PDFInk(), remote: remote).pdfHash == "remote")
    }

    @Test func invalidSideBecomesConflict() throws {
        let valid = try PDFInk().data()
        #expect(PDFInkKind.merge(base: nil, local: valid, remote: Data("{".utf8)) == nil)
        #expect(PDFInkKind.merge(base: nil, local: valid, remote: valid) == valid)
    }

    // MARK: Kind

    @Test func kindsAndCompanion() throws {
        let kinds = try KindRegistry([PDFKind.self, PDFInkKind.self])
        #expect(kinds.kind(for: "a/講義.pdf")?.id == PDFKind.id)
        #expect(kinds.kind(for: "a/講義.PDF.ink")?.id == PDFInkKind.id)
        #expect(kinds.mainFile(ofCompanion: "a/講義.pdf.ink") == "a/講義.pdf")
        #expect(kinds.mainFile(ofCompanion: "a/講義.pdf") == nil)
        #expect(PDFKind.merge(base: nil, local: Data([1]), remote: Data([2])) == nil) // 不透明 → 衝突副本
    }

    @Test func pdfIndexHasPageCount() {
        let entry = PDFKind.index(Sample.pdf(pages: 12), fileName: "講義.pdf")
        #expect(entry.title == "講義")
        #expect(entry.summary == "12 頁")
        #expect(entry.plainText.isEmpty)
        #expect(PDFKind.index(Data("壞掉".utf8), fileName: "x.pdf").summary == nil)
    }
}
