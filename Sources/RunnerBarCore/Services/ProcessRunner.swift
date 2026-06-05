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
/// rather than a bare `process.waitUntilExit()` with no deadline.
/// Reason: `waitUntilExit()` with no timeout can hang indefinitely if a child
/// process ignores SIGTERM or holds an open pipe. This pattern was the root
/// cause of the main-thread hang tracked in bug #477. The `DispatchWorkItem`
/// approach guarantees termination within `timeout` seconds even in that case.
/// Do NOT remove the timeout guard.
///
/// ## ⚠️ Pipe-drain concurrency — do NOT move readDataToEndOfFile after waitUntilExit
/// The stdout pipe is drained on a background thread *while* `waitUntilExit()`
/// blocks. If the drain is deferred until after exit, the kernel pipe buffer
/// (~64 KB on macOS) can fill up, causing the child process to block writing
/// and `waitUntilExit()` to spin forever (Apple QA1858). `launchctl list` on
/// a loaded Mac easily exceeds 64 KB.
///
/// ## Async variant
/// `runAsync` wraps `run` in a `withTaskCancellationHandler` +
/// `withCheckedContinuation` so callers in async contexts do not block a
/// cooperative thread. The blocking work is dispatched to
/// `DispatchQueue.global(qos:)` and the continuation is resumed from
/// `terminationHandler`. If the enclosing `Task` is cancelled before the
/// process exits, `task.terminate()` is called immediately.
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

        do {
            try task.run()
        } catch {
            log("ProcessRunner › launch error: \(error) — \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))")
            return Result(data: nil, exitCode: Int32.max)
        }

        // Write stdin after launch so the process is ready to consume it.
        if let inputPipe, let stdinData = stdin {
            inputPipe.fileHandleForWriting.write(stdinData)
            inputPipe.fileHandleForWriting.closeFile()
        }

        // Drain stdout pipe on a background thread *concurrently* with
        // waitUntilExit(). Deferring the read until after exit deadlocks
        // when stdout exceeds the kernel pipe buffer (~64 KB on macOS) —
        // the child blocks writing and waitUntilExit() never returns.
        // The semaphore joins the drain thread before we read outputData.
        //
        // `nonisolated(unsafe)`: the DispatchSemaphore.wait() below provides
        // the happens-before guarantee that the background write to outputData
        // is complete before this thread reads it. The Swift concurrency
        // checker cannot see through semaphores, so we suppress the diagnostic
        // explicitly rather than restructuring the intentional concurrency here.
        let drainSemaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outputData = Data()
        DispatchQueue.global().async {
            outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
            drainSemaphore.signal()
        }

        // ⚠️ DO NOT remove this DispatchWorkItem timeout.
        // See class-level doc comment and bug #477 for full context.
        let timeoutItem = DispatchWorkItem {
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

        // Wait for the drain thread to finish consuming any buffered output.
        // Bounded by the process lifetime + one pipe-flush; effectively instant
        // after waitUntilExit() returns.
        drainSemaphore.wait()

        let exitCode = task.terminationStatus
        log("ProcessRunner › exit=\(exitCode) bytes=\(outputData.count) — \(executableURL.lastPathComponent)")
        return Result(data: outputData.isEmpty ? nil : outputData, exitCode: exitCode)
    }

    // MARK: - Async

    /// Launches an executable asynchronously, freeing the cooperative thread pool
    /// while the subprocess runs.
    ///
    /// Internally dispatches all blocking work (`waitUntilExit`, pipe drain, timeout
    /// guard) to `DispatchQueue.global(qos:)` and bridges back to the caller via
    /// `withCheckedContinuation`. The timeout guard uses `withTaskCancellationHandler`
    /// so cancelling the enclosing `Task` immediately terminates the subprocess —
    /// no thread is held open waiting.
    ///
    /// All parameters mirror `run(_:)`; defaults are identical.
    ///
    /// - Note: The DispatchWorkItem timeout and concurrent pipe-drain invariants
    ///   described in the class-level doc comment are preserved inside this method.
    public static func runAsync(
        executableURL: URL,
        arguments: [String],
        stdin: Data? = nil,
        workingDirectory: URL? = nil,
        mergeStderr: Bool = false,
        timeout: TimeInterval = 20,
        qos: DispatchQoS = .userInitiated
    ) async -> Result {
        // Capture the process in a sendable box so the cancellation handler
        // can terminate it without touching the continuation.
        final class ProcessBox: @unchecked Sendable {
            var process: Process?
        }
        let box = ProcessBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                DispatchQueue.global(qos: qos.qosClass).async {
                    let result = ProcessRunner.run(
                        executableURL: executableURL,
                        arguments: arguments,
                        stdin: stdin,
                        workingDirectory: workingDirectory,
                        mergeStderr: mergeStderr,
                        timeout: timeout
                    )
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            box.process?.terminate()
        }
    }
}
