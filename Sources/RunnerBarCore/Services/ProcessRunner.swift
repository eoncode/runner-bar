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
/// The stdout pipe must be drained on a background thread *while*
/// `waitUntilExit()` blocks. Deferring the drain until after exit lets the
/// kernel pipe buffer (~64 KB on macOS) fill up, causing the child process to
/// block on a write and `waitUntilExit()` to spin forever (Apple QA1858).
/// `launchctl list` on a loaded Mac easily exceeds 64 KB.
///
/// `run` drains stdout into a plain `var` inside a `DispatchQueue.async` block
/// and reads it back after `drainQueue.sync {}` — the queue provides the
/// happens-before guarantee with zero unsafe annotations.
/// `runAsync` routes the drain through an `OutputAccumulator` actor, which
/// Swift 6.2 strict concurrency can verify independently.
///
/// ## Async variant (`runAsync`)
/// `runAsync` owns its own `Process` instance and bridges completion via
/// `terminationHandler` + `withCheckedContinuation` — no thread is held while
/// the subprocess runs. `withTaskCancellationHandler` wires `task.terminate()`
/// directly to Swift structured concurrency cancellation. A sibling
/// `Task.detached` replaces the `DispatchWorkItem` timeout from `run(_:)`.
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

    // MARK: - OutputAccumulator

    /// Actor-isolated stdout accumulator.
    ///
    /// Routing all pipe reads through an actor gives Swift 6.2 strict
    /// concurrency a compiler-verified happens-before relationship between
    /// the background drain thread and the reader — no `nonisolated(unsafe)`
    /// or `DispatchSemaphore` required.
    private actor OutputAccumulator {
        /// Accumulated bytes from the process stdout pipe.
        private var buffer = Data()
        /// Appends a chunk of bytes to the buffer.
        func append(_ chunk: Data) { buffer.append(chunk) }
        /// Returns all accumulated bytes.
        var data: Data { buffer }
    }

    // MARK: - Synchronous

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

        // Drain stdout on a dedicated queue concurrently with waitUntilExit().
        // See class-level doc: draining must overlap with waitUntilExit() to
        // prevent the kernel pipe buffer (~64 KB) from filling and deadlocking.
        //
        // `outputData` is written inside `drainQueue.async` and read only after
        // `drainQueue.sync {}` returns — the queue provides the happens-before
        // guarantee that the compiler can verify. No `nonisolated(unsafe)` or
        // `DispatchSemaphore` needed; the variable never crosses a concurrent
        // boundary.
        var outputData = Data()
        let drainQueue = DispatchQueue(label: "ProcessRunner.drain")
        drainQueue.async {
            outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
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

        // Join the drain queue — blocks until readDataToEndOfFile() has finished
        // writing `outputData`. After this point `outputData` is safe to read on
        // the calling thread; the queue serialisation is the happens-before edge.
        drainQueue.sync {}

        let exitCode = task.terminationStatus
        log("ProcessRunner › exit=\(exitCode) bytes=\(outputData.count) — \(executableURL.lastPathComponent)")
        return Result(data: outputData.isEmpty ? nil : outputData, exitCode: exitCode)
    }

    // MARK: - Async

    /// Launches an executable asynchronously without blocking the cooperative thread pool.
    ///
    /// Unlike `run(_:)`, this method owns its `Process` instance directly so that
    /// Swift structured concurrency can interact with it properly:
    ///
    /// - **Suspension:** the caller suspends at the `await` and is resumed by
    ///   `terminationHandler` when the process exits — no thread is held.
    /// - **Cancellation:** `withTaskCancellationHandler` calls `task.terminate()`
    ///   the moment the enclosing `Task` is cancelled (e.g. when `start()` replaces
    ///   `pollTask`), bounding latency to OS signal-delivery time rather than the
    ///   full `timeout`.
    /// - **Timeout:** a sibling `Task.detached` sleeps for `timeout` seconds and
    ///   then calls `task.terminate()` if the process is still running, preserving
    ///   the hang-safety guarantee of `run(_:)` without a `DispatchWorkItem`.
    ///
    /// ## ⚠️ Pipe-drain concurrency — same invariant as `run(_:)`
    /// stdout is drained on a `DispatchQueue.global` thread *concurrently* with
    /// process execution. All writes go through `OutputAccumulator` so Swift 6.2
    /// strict concurrency verifies correctness — no `nonisolated(unsafe)` needed.
    /// `terminationHandler` awaits the accumulated data before resuming the
    /// continuation, guaranteeing the buffer is fully written before it is read.
    ///
    /// All parameters mirror `run(_:)`; defaults are identical.
    public static func runAsync(
        executableURL: URL,
        arguments: [String],
        stdin: Data? = nil,
        workingDirectory: URL? = nil,
        mergeStderr: Bool = false,
        timeout: TimeInterval = 20
    ) async -> Result {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        if let workingDirectory { task.currentDirectoryURL = workingDirectory }

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = mergeStderr ? outPipe : FileHandle.nullDevice

        let inputPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            task.standardInput = p
            inputPipe = p
        } else {
            inputPipe = nil
        }

        let accumulator = OutputAccumulator()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                // Drain stdout on a background thread concurrently with process
                // execution. All writes go through the actor — no nonisolated(unsafe).
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    Task.detached { await accumulator.append(chunk) }
                }

                task.terminationHandler = { t in
                    // Stop the handler and drain any final bytes.
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    let tail = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let exitCode = t.terminationStatus
                    // Await the accumulator on a Task so terminationHandler
                    // (a non-async closure) can hand off to async context.
                    Task.detached {
                        await accumulator.append(tail)
                        let outputData = await accumulator.data
                        log("ProcessRunner › exit=\(exitCode) bytes=\(outputData.count) — \(executableURL.lastPathComponent)")
                        continuation.resume(returning: Result(
                            data: outputData.isEmpty ? nil : outputData,
                            exitCode: exitCode
                        ))
                    }
                }

                do {
                    try task.run()
                } catch {
                    log("ProcessRunner › launch error: \(error) — \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))")
                    continuation.resume(returning: Result(data: nil, exitCode: Int32.max))
                    return
                }

                if let inputPipe, let stdinData = stdin {
                    DispatchQueue.global(qos: .userInitiated).async {
                        inputPipe.fileHandleForWriting.write(stdinData)
                        inputPipe.fileHandleForWriting.closeFile()
                    }
                }

                // Timeout guard — terminates the process if it outlives `timeout`.
                Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        guard task.isRunning else { return }
                        log("ProcessRunner › timeout (\(timeout)s) — terminating \(executableURL.lastPathComponent)")
                        task.terminate()
                    } catch {
                        // CancellationError: process already exited, nothing to do.
                    }
                }
            }
        } onCancel: {
            // Enclosing Task was cancelled (e.g. pollTask replaced by start()).
            task.terminate()
        }
    }
}
