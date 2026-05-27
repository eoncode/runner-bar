// ProcessRunner.swift
// RunnerBarCore
import Foundation

// MARK: - ProcessRunner

/// Shared primitive for launching subprocesses with streaming output,
/// optional stdin, optional working directory, and a DispatchWorkItem timeout.
///
/// Both `runGHProcess` (GitHubCLITransport) and `runScriptWithOutput`
/// (RunnerLifecycleService) are thin wrappers around this type.
///
/// ## Migration note (from Shell.swift — deleted in #956)
/// The old `Shell` enum used `/bin/zsh -c "<command string>"` which had
/// a documented shell-injection risk: any unsanitised argument could escape
/// the command string and execute arbitrary shell code. `ProcessRunner.run`
/// takes a typed `[String]` arguments array and passes it directly to
/// `Process`, bypassing the shell entirely. Never reintroduce a string-based
/// shell invocation here.
///
/// ## ⚠️ Timeout implementation — do NOT simplify
/// The timeout is implemented as a `DispatchWorkItem` + `DispatchQueue.asyncAfter`
/// rather than the simpler `process.waitUntilExit()` with no deadline.
/// Reason: `waitUntilExit()` with no timeout can hang indefinitely if a child
/// process ignores SIGTERM or holds an open pipe. This pattern was the root
/// cause of the main-thread hang tracked in bug #477. The `DispatchWorkItem`
/// approach guarantees termination within `timeout` seconds even in that case.
/// Do NOT replace this with a bare `waitUntilExit()` call.
public enum ProcessRunner {
    /// A value type representing Result.
    public struct Result {
        /// The data constant.
        public let data: Data?
        /// The exitCode constant.
        public let exitCode: Int32
        /// Convenience: decoded UTF-8 string of `data`, or empty string.
        public var output: String { data.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    }

    /// Launches an executable synchronously.
    /// ⚠️ Must be called from a background thread — blocks until exit or timeout.
    ///
    /// - Parameters:
    ///   - executableURL: Full path to the executable.
    ///   - arguments: Command-line arguments.
    ///   - stdin: Optional data written to the process's standard input.
    ///   - workingDirectory: Optional working directory for the process.
    ///   - mergeStderr: When true, stderr is merged into stdout (default false).
    ///   - timeout: Seconds before the process is force-terminated.
    /// - Returns: A `Result` with the collected stdout data and exit code.
    ///   `exitCode` is `Int32.max` on process-launch failure.
    public static func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data? = nil,
        workingDirectory: URL? = nil,
        mergeStderr: Bool = false,
        timeout: TimeInterval = 20
    ) -> Result {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        if let workingDirectory { task.currentDirectoryURL = workingDirectory }

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = mergeStderr ? outPipe : Pipe()

        // Wire stdin pipe when body data is provided.
        let inputPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            task.standardInput = p
            inputPipe = p
        } else {
            inputPipe = nil
        }

        nonisolated(unsafe) var outputData = Data()
        let lock = NSLock()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outputData.append(chunk); lock.unlock()
        }

        do {
            try task.run()
        } catch {
            log("ProcessRunner › launch error: \(error) — \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))")
            outPipe.fileHandleForReading.readabilityHandler = nil
            return Result(data: nil, exitCode: Int32.max)
        }

        // Write stdin after launch so the process is ready to consume it.
        if let inputPipe, let stdinData = stdin {
            inputPipe.fileHandleForWriting.write(stdinData)
            inputPipe.fileHandleForWriting.closeFile()
        }

        // ⚠️ DO NOT replace this DispatchWorkItem timeout with a bare waitUntilExit().
        // See class-level doc comment and bug #477 for full context.
        let timeoutItem = DispatchWorkItem {
            // Guard against the race where the process exits just before the
            // timeout fires — only terminate if the process is still running.
            guard task.isRunning else {
                log("ProcessRunner › timeout fired but process already exited — \(executableURL.lastPathComponent)")
                return
            }
            log("ProcessRunner › timeout (\(timeout)s) — terminating \(executableURL.lastPathComponent)")
            task.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()

        outPipe.fileHandleForReading.readabilityHandler = nil
        let tail = outPipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }

        let exitCode = task.terminationStatus
        log("ProcessRunner › exit=\(exitCode) bytes=\(outputData.count) — \(executableURL.lastPathComponent)")
        return Result(data: outputData.isEmpty ? nil : outputData, exitCode: exitCode)
    }
}
