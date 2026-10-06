import Foundation
import Testing
@testable import EasyNotesCore

struct DiagnosticsTests {
    private func tempStore(limit: Int = 30) -> DiagnosticsStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        return DiagnosticsStore(directory: dir, limit: limit)
    }

    @Test func storeKeepsNewestUpToLimit() throws {
        let store = tempStore(limit: 3)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for i in 0..<5 {
            try store.save(kind: "diagnostic", json: Data("{\"i\":\(i)}".utf8), date: Date(timeIntervalSince1970: Double(i) * 60))
        }
        let files = store.files()
        #expect(files.count == 3)
        let kept = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(kept == ["{\"i\":2}", "{\"i\":3}", "{\"i\":4}"])
    }

    @Test func samePayloadSecondDoesNotOverwrite() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let date = Date(timeIntervalSince1970: 1_000)
        try store.save(kind: "metric", json: Data("{\"a\":1}".utf8), date: date)
        try store.save(kind: "metric", json: Data("{\"a\":2}".utf8), date: date)
        #expect(store.files().count == 2)
    }

    @Test func reportEmbedsPayloadsAsJSONAndSkipsInvalid() throws {
        let env = DiagnosticsReport.Environment(appVersion: "1.2.0", build: "1", os: "15.0.0", model: "Mac", scope: "process")
        let report = DiagnosticsReport(generated: Date(timeIntervalSince1970: 0), environment: env,
                                       logs: [.init(date: Date(timeIntervalSince1970: 1), level: "error", category: "sync", message: "x")],
                                       payloads: [Data("{\"crash\":{\"n\":2,\"ok\":true}}".utf8), Data("not json".utf8)])
        let object = try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any]
        let payloads = try #require(object?["payloads"] as? [[String: Any]])
        #expect(payloads.count == 1)
        let crash = try #require(payloads[0]["crash"] as? [String: Any])
        #expect(crash["n"] as? Int == 2)
        #expect(crash["ok"] as? Bool == true)
        #expect((object?["logs"] as? [Any])?.count == 1)
    }

    @Test func describeNeverIncludesTheMessage() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "no such file: Secrets/passwords.md"])
        let text = DiagnosticsLog.describe(error)
        #expect(text == "NSCocoaErrorDomain:4")
        #expect(!text.contains("passwords"))
    }

    @Test func collectReadsLogsWithoutThrowing() throws {
        let store = tempStore()
        let report = DiagnosticsReport.collect(store: store, since: Date().addingTimeInterval(-60), maxLines: 10)
        #expect(["system", "process", "unavailable"].contains(report.environment.scope))
        #expect(report.payloads.isEmpty)
    }
}
