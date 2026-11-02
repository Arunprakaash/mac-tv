import Foundation
import OSLog

/// Mac TV's log, one category per area, in Console.app under the subsystem `local.couch.tv`.
///
/// Values are private unless marked `privacy: .public`, and private values show as <private> in
/// the diagnostics report. Mark only plain facts public: states, kinds, counts, error codes. Never
/// titles, web or server addresses, file or folder names, profile or device names.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "local.couch.tv"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let movies = Logger(subsystem: subsystem, category: "movies")
    static let remote = Logger(subsystem: subsystem, category: "remote")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let updates = Logger(subsystem: subsystem, category: "updates")
    static let system = Logger(subsystem: subsystem, category: "system")
}

extension Logger {
    /// Logs a failure with its error domain and code public and its description private, since
    /// descriptions often carry file paths or addresses.
    func failure(_ what: String, _ error: Error) {
        if let error = error as? PublicError {
            self.error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let error = error as NSError
        self.error("\(what, privacy: .public): \(error.domain, privacy: .public) \(error.code, privacy: .public) \(error.localizedDescription)")
    }

    /// Runs a step whose failure mustn't stop Mac TV, like saving a list, and logs it if it fails.
    /// Returns nil then, like `try?`.
    @discardableResult
    func attempt<T>(_ what: String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            failure(what, error)
            return nil
        }
    }
}

/// An error of Mac TV's own whose messages are fixed text with nothing personal in them, so the
/// log can show them in full.
protocol PublicError: LocalizedError {}
