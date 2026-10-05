import EasyNotesCore
import Foundation
import Testing
@testable import KindPDF

/// `.pdf.ink` 旁檔與 `.pdf` 本身都可能被竄改（security.md「外掛與檔案解析」）
struct PDFParserFuzzTests {
    static let ink = [
        #"{"type":"easynotes-pdf-ink","version":1,"pdfHash":"abc","pages":{"0":{"elements":[{"id":"a","type":"freedraw","points":[[0,0],[1,1]],"version":1}]}}}"#,
        #"{"type":"easynotes-pdf-ink"}"#, "",
    ].map { Data($0.utf8) }

    static let pdf = Data("""
    %PDF-1.1
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj
    trailer<</Root 1 0 R/Size 4>>
    %%EOF
    """.utf8)

    @Test func inkSurvivesAnyBytes() {
        var n = 0
        let slow = Fuzz.run(seeds: Self.ink, rounds: 500) { data in
            n += 1
            _ = PDFInkKind.index(data, fileName: "a.pdf.ink")
            _ = PDFInkKind.merge(base: nil, local: data, remote: Self.ink[n % Self.ink.count])
            _ = PDFInkKind.merge(base: nil, local: Self.ink[n % Self.ink.count], remote: data)
            if let ink = try? PDFInk(data: data) { _ = try? ink.data() }
        }
        #expect(slow.isEmpty, "\(slow)")
    }

    @Test func extremeInkValuesDoNotCrash() {
        let inputs = [
            #"{"type":"easynotes-pdf-ink","pages":{"-1":{"elements":[{"id":"a","version":1e999}]},"99999999999999999999":{}}}"#,
            #"{"type":"easynotes-pdf-ink","pages":[],"pdfHash":5}"#,
            #"{"type":"easynotes-pdf-ink","pages":{"0":{"elements":[[[[[]]]],null,1e999]}}}"#,
            "{\"type\":\"easynotes-pdf-ink\",\"pages\":" + String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000) + "}",
        ].map { Data($0.utf8) }
        for data in inputs {
            _ = PDFInkKind.merge(base: nil, local: data, remote: Self.ink[0])
            _ = PDFInkKind.merge(base: nil, local: Self.ink[0], remote: data)
            if let ink = try? PDFInk(data: data) { _ = try? ink.data() }
        }
    }

    @Test func pdfIndexSurvivesAnyBytes() {
        let slow = Fuzz.run(seeds: [Self.pdf], rounds: 300, limit: 5) { data in
            _ = PDFKind.index(data, fileName: "a.pdf")
        }
        #expect(slow.isEmpty, "\(slow)")
    }
}
