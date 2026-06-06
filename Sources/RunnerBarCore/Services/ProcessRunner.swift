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
///
/// ## Async variant (`runAsync`)
/// `runAsync` owns its own `Process` instance and bridges completion via
/// `terminationHandler` + `withCheckedContinuation` — no thread is held while
/// the subprocess runs. `withTaskCancellationHandler` wires `task.terminate()`
/// directly to Swift structured concurrency cancellation. A sibling
/// `Task.detached` replaces the `DispatchWorkItem` timeout from `run(_:)`.
/// Tiny mutable reference wrapper used only to bridge `DispatchQueue.async` /
/// `terminationHandler` closures to outer local state without tripping Swift 6.2
/// `#SendableClosureCaptures` diagnostics.
///
/// Why `@unchecked Sendable` is acceptable here:
/// - The *box reference* is captured as a `let` constant by the `@Sendable` closure.
/// - Only the stored `value` field is mutated.
/// - Mutation is serialised by a dedicated private queue (`drainQueue`).
/// - A matching `drainQueue.sync {}` barrier establishes the happens-before edge
///   before the outer function reads `value`.
///
/// In other words, this is not shared unsynchronised mutable state; it is a tiny,
/// queue-confined handoff cell. Replacing it with an actor would complicate the
/// subprocess drain path without improving safety.
private final class Box<T>: @unchecked Sendable {
    /// The wrapped mutable value.
    var value: T
    /// Creates a box with the given initial value.
    init(_ initial: T) { value = initial }
}

/// Shared primitive for launching subprocesses. See file-level doc comment above for full details.
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
        // We use a single-element array as a heap-allocated mutable box.
        // The array itself is a `let` constant captured by the closure — only the
        // *element* is mutated, which is valid without `nonisolated(unsafe)` and
        // avoids the Swift 6.2 `#SendableClosureCaptures` diagnostic.
        // `drainQueue.sync {}` after `waitUntilExit()` provides the happens-before
        // guarantee: the write at [0] is always complete before we read it.
        let outputBox = Box<Data>(Data())
        let drainQueue = DispatchQueue(label: "ProcessRunner.drain")
        drainQueue.async {
            outputBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // ⚠️ DO NOT remove this DispatchWorkItem timeout.
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

        // Join the drain queue — blocks until readDataToEndOfFile() has finished
        // writing outputBox.value. After this sync barrier the value is safe to
        // read on the calling thread; the queue serialisation is the happens-before edge.
        drainQueue.sync {}

        let exitCode = task.terminationStatus
        let outputData = outputBox.value
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
    /// stdout is drained via a dedicated serial `DispatchQueue` *concurrently* with
    /// process execution, mirroring the `Box + drainQueue.sync` pattern in `run(_:)`.
    /// `readDataToEndOfFile()` blocks until the pipe's write end closes (i.e. the
    /// process exits), so all bytes are captured in a single call with one clear
    /// happens-before edge. `terminationHandler` joins the drain queue with
    /// `drainQueue.sync {}` before reading the result — no actor, no lock, no
    /// fire-and-forget tasks required.
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

        // Drain stdout on a dedicated serial queue concurrently with process execution,
        // mirroring the run() synchronous pattern. readDataToEndOfFile() blocks until
        // the write end of the pipe is closed (i.e. the process exits), so it captures
        // all output in one call with a single clear happens-before edge.
        //
        // Using a DispatchQueue here (not a Task) keeps the drain off the cooperative
        // thread pool, avoids the fire-and-forget Task.detached-per-chunk pattern, and
        // ensures drainQueue.sync {} in terminationHandler is the sole synchronisation
        // point — no actor, no lock, no untracked tasks required.
        let outputBox = Box<Data>(Data())
        let drainQueue = DispatchQueue(label: "ProcessRunner.drain.async")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                drainQueue.async {
                    outputBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
                }

                // Timeout guard — terminates the process if it outlives `timeout`.
                // Box<Task?> is used so terminationHandler (a @Sendable closure) can capture
                // a reference type (let) rather than a var, satisfying Swift 6.2 strict
                // concurrency. The box is written once after task.run() and read once inside
                // terminationHandler — both on the same serialised execution path (#1152).
                let timeoutTaskBox = Box<Task<Void, Never>?>(nil)

                task.terminationHandler = { t in
                    let exitCode = t.terminationStatus
                    // Cancel the timeout guard immediately — process has already exited.
                    timeoutTaskBox.value?.cancel()
                    // Join the drain queue: blocks until readDataToEndOfFile() finishes.
                    // This is the happens-before guarantee that makes outputBox.value safe
                    // to read immediately after. The drainQueue.sync call is cheap here
                    // because the process has already exited and the pipe is closed.
                    drainQueue.sync {}
                    let outputData = outputBox.value
                    log("ProcessRunner › exit=\(exitCode) bytes=\(outputData.count) — \(executableURL.lastPathComponent)")
                    continuation.resume(returning: Result(
                        data: outputData.isEmpty ? nil : outputData,
                        exitCode: exitCode
                    ))
                }

                // Guard against the already-cancelled case: Swift invokes onCancel
                // *before* this operation closure when the task is cancelled at the
                // moment withTaskCancellationHandler is called. onCancel's
                // `guard task.isRunning` no-ops in that scenario, so we must also
                // bail here before task.run() to honour cancellation rather than
                // launching the process normally.
                if Task.isCancelled {
                    outPipe.fileHandleForWriting.closeFile()
                    continuation.resume(returning: Result(data: nil, exitCode: Int32.max))
                    return
                }

                do {
                    try task.run()
                } catch {
                    log("ProcessRunner › launch error: \(error) — \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))")
                    // Close the write end of the pipe so readDataToEndOfFile() in the
                    // already-dispatched drainQueue.async block receives EOF and returns.
                    // Without this, the drain closure blocks indefinitely (Process.deinit
                    // skips pipe teardown when hasLaunched == false), leaking the GCD
                    // worker thread for the lifetime of the app.
                    outPipe.fileHandleForWriting.closeFile()
                    continuation.resume(returning: Result(data: nil, exitCode: Int32.max))
                    return
                }

                if let inputPipe, let stdinData = stdin {
                    // stdin writing remains on DispatchQueue.global deliberately:
                    // no current call site of runAsync passes stdin, so this path
                    // is dormant and has never been exercised in production.
                    //
                    // WARNING — do not activate without fixing the ordering first:
                    // this fire-and-forget write has no synchronisation with
                    // terminationHandler. If the process exits before the write
                    // completes, closeFile() races against drainQueue.sync{} and
                    // continuation.resume() — a data race on the pipe file handle.
                    // Fix: write stdin synchronously before drainQueue.async, or
                    // use a dedicated serial queue with an explicit barrier.
                    // Tracked as part of issue #1077 (mutation-path async migration).
                    DispatchQueue.global(qos: .userInitiated).async {
                        inputPipe.fileHandleForWriting.write(stdinData)
                        inputPipe.fileHandleForWriting.closeFile()
                    }
                }

                timeoutTaskBox.value = Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        guard task.isRunning else { return }
                        log("ProcessRunner › timeout (\(timeout)s) — terminating \(executableURL.lastPathComponent)")
                        task.terminate()
                    } catch {
                        // CancellationError from timeoutTask.cancel() — process already done.
                    }
                }
            }
        } onCancel: {
            // Enclosing Task was cancelled (e.g. pollTask replaced by start()).
            // terminate() signals the subprocess; terminationHandler fires and resumes
            // the continuation, so the awaiting Task unblocks and exits cleanly.
            //
            // Swift docs: if the task is already cancelled when withTaskCancellationHandler
            // is called, onCancel fires synchronously *before* the operation closure runs.
            // In that case task.run() has not been called yet — isRunning is false and
            // terminate() would be a no-op on Darwin, but the process would then start
            // normally when the operation eventually runs, violating cancellation semantics.
            // The guard ensures we only signal a live process, and the Task.isCancelled
            // check at the top of the operation catches the already-cancelled path before
            // task.run() is reached.
            guard task.isRunning else { return }
            task.terminate()
        }
    }
}
