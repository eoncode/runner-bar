import Foundation

/// Runs `launchPath` with `arguments`, captures stdout, trims whitespace.
/// Blocks the calling thread; always call off the main queue.
///
/// Enforces a 20-second hard timeout: if the process has not exited by then
/// it is terminated and an empty string is returned. Stdout is drained
/// asynchronously to avoid deadlocks on large output.
///
/// - Returns: Trimmed stdout string, or empty string on failure or timeout.
@discardableResult
func shell(_ launchPath: String, _ arguments: [String] = []) -> String {
    let task = Process()
    task.launchPath = launchPath
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()

    var outputData = Data()
    let readSemaphore = DispatchSemaphore(value: 0)

    // Drain stdout asynchronously to avoid blocking on large payloads.
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
            pipe.fileHandleForReading.readabilityHandler = nil
            readSemaphore.signal()
        } else {
            outputData.append(chunk)
        }
    }

    do {
        try task.run()
    } catch {
        return ""
    }

    // Wait up to 20 seconds for the process to finish.
    let deadline = DispatchTime.now() + .seconds(20)
    let exitResult = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        task.waitUntilExit()
        exitResult.signal()
    }
    if exitResult.wait(timeout: deadline) == .timedOut {
        task.terminate()
        pipe.fileHandleForReading.readabilityHandler = nil
        return ""
    }

    // Wait for the read handler to drain any remaining bytes (up to 2 s).
    _ = readSemaphore.wait(timeout: .now() + .seconds(2))

    return String(data: outputData, encoding: .utf8)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
}
