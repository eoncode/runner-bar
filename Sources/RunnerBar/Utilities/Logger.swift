import Foundation

/// Writes a timestamped, file-annotated message to stderr.
/// Visible in Terminal, Console.app, and crash logs.
func log(
    _ message: String,
    file: String = #file,
    line: Int = #line
) {
    let filename = URL(fileURLWithPath: file)
        .deletingPathExtension().lastPathComponent
    let timestamp = _logFormatter.string(from: Date())
    fputs("[RunnerBar \(timestamp)] \(filename):\(line) — \(message)\n", stderr)
}

/// Shared ISO-8601 formatter for log timestamps.
/// ISO8601DateFormatter is expensive to allocate; keeping one static instance
/// avoids repeated allocation on every `log()` call.
private let _logFormatter = ISO8601DateFormatter()
