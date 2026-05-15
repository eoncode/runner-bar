import Foundation

/// Runs `command` via zsh, draining stdout/stderr asynchronously to avoid
/// pipe-buffer deadlock, and enforcing a hard timeout so the app never hangs.
@discardableResult
func shell(_ command: String, timeout: TimeInterval = 20) -> String {
    log("shell › \(command)")
    let task = Process()
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.launchPath = "/bin/zsh"
    task.arguments = ["-c", command]

    // Drain pipe asynchronously — prevents pipe-buffer deadlock when the
    // subprocess produces more output than the kernel buffer can hold.
    var outputData = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock(); outputData.append(chunk); lock.unlock()
    }

    do {
        try task.run()
    } catch {
        log("shell › launch error: \(error)")
        pipe.fileHandleForReading.readabilityHandler = nil
        return ""
    }

    // Hard timeout: if gh CLI hangs (network stall, auth expiry, etc.) we
    // terminate it rather than blocking the thread indefinitely.
    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning {
        if Date() > deadline {
            log("shell › timeout (\(Int(timeout))s) — terminating: \(command)")
            task.terminate()
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    // Stop the handler, then drain any final bytes that arrived between the
    // last readabilityHandler call and the process exiting.
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }

    let result = String(data: outputData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    log("shell › exit \(task.terminationStatus), \(outputData.count) bytes")
    return result
}
