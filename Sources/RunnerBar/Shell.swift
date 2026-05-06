import Foundation

/// Runs `launchPath` with `arguments`, captures stdout, trims whitespace.
/// Blocks the calling thread; always call off the main queue.
///
/// - Returns: Trimmed stdout string, or empty string on failure.
@discardableResult
func shell(_ launchPath: String, _ arguments: [String] = []) -> String {
    let task = Process()
    task.launchPath = launchPath
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return ""
    }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
