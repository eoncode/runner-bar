import Foundation

// swiftlint:disable missing_docs

/// Executes shell commands synchronously.
enum Shell {
    /// Result of a shell command execution.
    struct Result {
        /// Standard output text.
        let output: String
        /// Exit code returned by the process.
        let exitCode: Int32
    }

    /// Runs `command` in `/bin/zsh -c` and returns the trimmed output + exit code.
    @discardableResult
    static func run(_ command: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return Result(output: error.localizedDescription, exitCode: -1)
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Result(output: output, exitCode: process.terminationStatus)
    }
}

// MARK: - Backward-compatibility shim
// Legacy call-sites use shell("cmd", timeout: N) -> String.
// New code should prefer Shell.run(_:) directly.
@discardableResult
func shell(_ command: String, timeout: TimeInterval = 20) -> String {
    log("Shell:\(#line) \u{2014} shell \u{203A} \(command)")
    let task = Process()
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError  = pipe
    task.launchPath     = "/bin/zsh"
    task.arguments      = ["-c", command]

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
        log("Shell:\(#line) \u{2014} shell \u{203A} launch error: \(error)")
        pipe.fileHandleForReading.readabilityHandler = nil
        return ""
    }

    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning {
        if Date() > deadline {
            log("Shell:\(#line) \u{2014} shell \u{203A} timeout (\(Int(timeout))s) \u{2014} terminating: \(command)")
            task.terminate()
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }

    let result = String(data: outputData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    log("Shell:\(#line) \u{2014} shell \u{203A} exit \(task.terminationStatus), \(outputData.count) bytes")
    return result
}

// swiftlint:enable missing_docs
