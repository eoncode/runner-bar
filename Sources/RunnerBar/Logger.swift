import Foundation
import OSLog

// MARK: - Unified logger instances (for log stream / Console.app)

extension Logger {
    static let app   = Logger(subsystem: "dev.eonist.runnerbar", category: "app")
    static let fetch = Logger(subsystem: "dev.eonist.runnerbar", category: "fetch")
    static let store = Logger(subsystem: "dev.eonist.runnerbar", category: "store")
    static let auth  = Logger(subsystem: "dev.eonist.runnerbar", category: "auth")
}

// MARK: - File logger

/// Writes a timestamped log line to ~/Library/Logs/RunnerBar/runnerbar.log.
/// Works regardless of how the app is launched or signed.
/// Tail with: tail -f ~/Library/Logs/RunnerBar/runnerbar.log
func log(
    _ message: String,
    logger: Logger = .app,
    file: String = #file,
    line: Int = #line
) {
    let filename = URL(fileURLWithPath: file)
        .deletingPathExtension().lastPathComponent
    let timestamp = _logFormatter.string(from: Date())
    let line_str = "[RunnerBar \(timestamp)] \(filename):\(line) — \(message)\n"

    // 1. File log — always visible
    _fileLogger.write(line_str)

    // 2. OSLog — visible in Console.app / log stream when subsystem is trusted
    logger.debug("\(filename, privacy: .public):\(line, privacy: .public) — \(message, privacy: .public)")
}

/// Shared ISO-8601 formatter.
private let _logFormatter = ISO8601DateFormatter()

// MARK: - FileLogger

private final class FileLogger {
    private let fileHandle: FileHandle?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RunnerBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("runnerbar.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8),
              let fh = fileHandle else { return }
        fh.write(data)
    }
}

private let _fileLogger = FileLogger()
