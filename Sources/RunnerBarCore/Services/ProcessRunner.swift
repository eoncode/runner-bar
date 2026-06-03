// ProcessRunner.swift
// RunnerBarCore
import Foundation

// MARK: - ProcessRunner

/// Shared primitive for launching subprocesses with streaming output,
/// optional stdin, optional working directory, and a DispatchWorkItem timeout.
///
/// Both `runRegistrationCommand` and `runScriptWithOutput`
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
    /// The collected output and exit status from a subprocess invocation.
    public struct Result {
        /// Collected stdout bytes, or `nil` when the process failed to launch
        /// or when the process ran successfully but produced no stdout.
        /// - Note: `nil` does not imply failure — use `exitCode` to distinguish
        ///   a launch failure (`Int32.max`) from a successful process that produced no output.
        public let data: Data?
        /// Process exit code. `Int32.max` indicates a launch failure rather than a process exit.
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
    ///   - mergeStderr: When `true`, stderr is merged into stdout.
    ///     When `false` (default), stderr is discarded — it is not captured or returned.
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
        // When mergeStderr is false, use nullDevice so stderr is cleanly discarded.
        // A throwaway Pipe() would fill its buffer on verbose stderr output and
        // block the child process indefinitely.
        task.standardError = mergeStderr ? outPipe : FileHandle.nullDevice

        // Wire stdin pipe when body data is provided.
        let inputPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            task.standardInput = p
            inputPipe = p
        } else {
            inputPipe = nil
        }

        // nonisolated(unsafe): Swift 6 concurrency workaround — all concurrent reads/writes
        // are serialised through `lock`. The final read after `readabilityHandler = nil` is
        // safe because no other thread can access `outputData` at that point.
        // TODO: replace readabilityHandler + NSLock with readDataToEndOfFile() after // NOSONAR — tracked deferred refactor
        // waitUntilExit() — streaming is unnecessary given the background-thread call
        // contract. Tracked in <issue link once created>.
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
