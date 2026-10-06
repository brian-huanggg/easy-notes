import Foundation
import OSLog

/// The one place loggers are made, so every module shares a subsystem and the diagnostics export can filter by it.
/// Security invariant 7 applies: nothing that can be note content (text, titles, vault paths, error descriptions that
/// embed a path) is interpolated without `privacy: .private`. Use `describe(_:)` to log an error's shape in public.
public enum DiagnosticsLog {
    public static let subsystem = "app.easynotes"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// `domain:code` of an error. Safe to log publicly: unlike `localizedDescription` it never embeds a file name or content.
    public static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain):\(e.code)"
    }
}
