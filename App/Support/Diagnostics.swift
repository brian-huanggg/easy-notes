import EasyNotesCore
import MetricKit
import SwiftUI
import UniformTypeIdentifiers

/// Observability glue (design in security.md "Diagnostics"). Everything stays on this device: MetricKit payloads are
/// kept in Application Support and only leave through the user's own "Export diagnostics" action.
enum Diagnostics {
    private static let collector = MetricKitCollector()

    /// Called once at launch. MetricKit delivers a crash or hang report on the launch after it happened (at most daily).
    static func start() {
        guard !TestHooks.isUITest else { return }
        MXMetricManager.shared.add(collector)
    }

    /// Builds the export off the main thread (reading the system log store takes a moment).
    static func makeExport() async throws -> (data: Data, fileName: String) {
        try await Task.detached(priority: .utility) {
            let report = DiagnosticsReport.collect(store: try DiagnosticsStore.standard())
            return (try report.jsonData(), report.suggestedFileName)
        }.value
    }
}

private final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, Sendable {
    private let log = DiagnosticsLog.logger("metrickit")

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let store = try? DiagnosticsStore.standard() else { return }
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            do {
                try store.save(kind: "diagnostic", json: payload.jsonRepresentation(), date: payload.timeStampEnd)
                log.notice("diagnostic payload stored: \(crashes) crashes, \(hangs) hangs")
            } catch {
                log.error("storing diagnostic payload failed: \(DiagnosticsLog.describe(error), privacy: .public)")
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let store = try? DiagnosticsStore.standard() else { return }
        for payload in payloads {
            do { try store.save(kind: "metric", json: payload.jsonRepresentation(), date: payload.timeStampEnd) }
            catch { log.error("storing metric payload failed: \(DiagnosticsLog.describe(error), privacy: .public)") }
        }
    }
}

/// A JSON file handed to `fileExporter` (a save panel on Mac, the Files picker on iOS).
struct DiagnosticsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
