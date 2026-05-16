import Foundation
import OSLog

// MARK: - Unified logger instances

extension Logger {
    static let app   = Logger(subsystem: "dev.eonist.runnerbar", category: "app")
    static let fetch = Logger(subsystem: "dev.eonist.runnerbar", category: "fetch")
    static let store = Logger(subsystem: "dev.eonist.runnerbar", category: "store")
    static let auth  = Logger(subsystem: "dev.eonist.runnerbar", category: "auth")
}

// MARK: - Legacy shim

/// Writes a timestamped message via os_log (visible in `log stream` + Console.app).
/// Category defaults to "app"; pass a specific Logger via the `logger` param for finer control.
func log(
    _ message: String,
    logger: Logger = .app,
    file: String = #file,
    line: Int = #line
) {
    let filename = URL(fileURLWithPath: file)
        .deletingPathExtension().lastPathComponent
    logger.debug("\(filename, privacy: .public):\(line, privacy: .public) — \(message, privacy: .public)")
}
