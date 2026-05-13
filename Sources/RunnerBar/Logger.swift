import Foundation

/// Shared formatter — ISO8601DateFormatter is expensive to init;
/// hoisted here so it is created once for the lifetime of the process.
private let _logFormatter = ISO8601DateFormatter()

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
