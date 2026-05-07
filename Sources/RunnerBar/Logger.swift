import Foundation

/// Writes a timestamped, file-annotated message to stderr.
/// Visible in Terminal, Console.app, and crash logs.
func log( // swiftlint:disable:this missing_docs
    _ message: String,
    file: String = #file,
    line: Int = #line
) {
    let filename = URL(fileURLWithPath: file)
        .deletingPathExtension().lastPathComponent
    let formatter = ISO8601DateFormatter()
    let timestamp = formatter.string(from: Date())
    fputs("[RunnerBar \(timestamp)] \(filename):\(line) — \(message)\n", stderr)
}
