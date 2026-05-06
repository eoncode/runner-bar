import Foundation

/// Runs `command` via zsh, draining stdout/stderr asynchronously to avoid
/// pipe-buffer deadlock, and enforcing a hard timeout so the app never hangs.
@discardableResult
func shell(_ command: String, timeout: TimeInterval = 20) -> String {
    log("shell \u203a \(command)")
    let task = Process()
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.launchPath = "/bin/zsh"
    task.arguments = ["-c", command]

    var outputData = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        outputData.append(chunk)
        lock.unlock()
    }

    do {
        try task.run()
    } catch {
        log("shell \u203a launch error: \(error)")
        pipe.fileHandleForReading.readabilityHandler = nil
        return ""
    }

    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning {
        if Date() > deadline {
            log("shell \u203a timeout (\(Int(timeout))s) \u2014 terminating: \(command)")
            task.terminate()
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty {
        lock.lock()
        outputData.append(tail)
        lock.unlock()
    }
    let result = String(data: outputData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    log("shell \u203a exit \(task.terminationStatus), \(outputData.count) bytes")
    return result
}
