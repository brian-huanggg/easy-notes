import Foundation
import OSLog

/// What the "Export diagnostics" button writes: this app's recent log lines, the stored MetricKit payloads and the
/// environment. It holds no vault content: logs are filtered to our own subsystem and their `.private` values stay redacted.
public struct DiagnosticsReport: Sendable {
    public struct LogLine: Sendable, Codable, Equatable {
        public var date: Date
        public var level: String
        public var category: String
        public var message: String
    }

    public struct Environment: Sendable, Codable, Equatable {
        public var appVersion: String
        public var build: String
        public var os: String
        public var model: String
        public var scope: String   // which log store was read, so a short log is explainable
    }

    public var generated: Date
    public var environment: Environment
    public var logs: [LogLine]
    /// Raw MetricKit JSON, oldest first.
    public var payloads: [Data]

    public init(generated: Date = Date(), environment: Environment, logs: [LogLine], payloads: [Data]) {
        self.generated = generated
        self.environment = environment
        self.logs = logs
        self.payloads = payloads
    }

    /// Reads the log store and the payload files. macOS reads the system-wide store (works for an admin user, no
    /// entitlement) and falls back to this process only; iOS has no system scope, so it sees this launch only.
    public static func collect(store: DiagnosticsStore, since: Date = Date().addingTimeInterval(-24 * 3600), maxLines: Int = 5_000) -> DiagnosticsReport {
        let (lines, scope) = readLogs(since: since, maxLines: maxLines)
        let payloads = store.files().compactMap { try? Data(contentsOf: $0) }
        return DiagnosticsReport(environment: .current(logScope: scope), logs: lines, payloads: payloads)
    }

    static func readLogs(since: Date, maxLines: Int) -> ([LogLine], String) {
        var candidates: [(OSLogStore, String)] = []
        #if os(macOS)
        if let s = try? OSLogStore(scope: .system) { candidates.append((s, "system")) }
        #endif
        if let s = try? OSLogStore(scope: .currentProcessIdentifier) { candidates.append((s, "process")) }
        for (log, scope) in candidates {
            let predicate = NSPredicate(format: "subsystem == %@", DiagnosticsLog.subsystem)
            guard let entries = try? log.getEntries(at: log.position(date: since), matching: predicate) else { continue }
            var lines: [LogLine] = []
            for case let e as OSLogEntryLog in entries {
                lines.append(LogLine(date: e.date, level: e.level.name, category: e.category, message: e.composedMessage))
                if lines.count >= maxLines { break }
            }
            return (lines, scope)
        }
        return ([], "unavailable")
    }

    /// One pretty-printed JSON document. Payloads that are not valid JSON are skipped rather than failing the export.
    public func jsonData() throws -> Data {
        struct Document: Encodable {
            var generated: Date
            var environment: Environment
            var logs: [LogLine]
            var payloads: [AnyJSON]
        }
        let doc = Document(generated: generated, environment: environment, logs: logs,
                           payloads: payloads.compactMap { try? JSONSerialization.jsonObject(with: $0) }.map(AnyJSON.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    public var suggestedFileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "EasyNotes-diagnostics-\(f.string(from: generated)).json"
    }
}

extension DiagnosticsReport.Environment {
    static func current(logScope: String) -> Self {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Self(appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
                    build: info["CFBundleVersion"] as? String ?? "?",
                    os: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                    model: hardwareModel(),
                    scope: logScope)
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private extension OSLogEntryLog.Level {
    var name: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "undefined"
        }
    }
}

/// Re-encodes a `JSONSerialization` object tree, so MetricKit's JSON is embedded as JSON rather than as an escaped string.
private struct AnyJSON: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as [String: Any]: try c.encode(v.mapValues(AnyJSON.init))
        case let v as [Any]: try c.encode(v.map(AnyJSON.init))
        case let v as String: try c.encode(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { try c.encode(v.boolValue) }
            else if v.doubleValue == v.doubleValue.rounded(), abs(v.doubleValue) < 9e15 { try c.encode(v.int64Value) }
            else { try c.encode(v.doubleValue) }
        default: try c.encodeNil()
        }
    }
}
