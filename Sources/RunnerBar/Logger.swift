import Foundation
/// Writes a timestamped, file-annotated message to stderr.
/// Visible in Terminal when running the app from the shell,
/// in Console.app under the process name, and in crash logs.
func log(
    _ message: String,
    file: String = #file,
    line: Int = #line
) {
    let filename = URL(fileURLWithPath: file)
        .deletingPathExtension().lastPathComponent
    let isoTimestamp = ISO8601DateFormatter().string(from: Date())
    fputs("[RunnerBar \(isoTimestamp)] \(filename):\(line) — \(message)\n", stderr)
}
