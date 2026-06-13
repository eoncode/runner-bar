// ProcessRunner.swift
// RunnerBarCore
import Foundation
import os

// MARK: - ProcessRunner

// Shared primitive for launching subprocesses with streaming output,
// optional stdin, optional working directory, and a DispatchWorkItem timeout.
//
// Both `runRegistrationCommand` and `runScriptWithOutput`
// (RunnerLifecycleService) are thin wrappers around this type.
//
// ## Migration note (from Shell.swift — deleted in #956)
// The old `Shell` enum used `/bin/zsh -c "<command string>"` which had
// a documented shell-injection risk: any unsanitised argument could escape
// the command string and execute arbitrary shell code. `ProcessRunner.run`
// takes a typed `[String]` arguments array and passes it directly to
// `Process`, bypassing the shell entirely. Never reintroduce a string-based
// shell invocation here.
//
// ## ⚠️ Timeout implementation — do NOT simplify
// The timeout is implemented as a `DispatchWorkItem` + `DispatchQueue.asyncAfter`
// rather than a bare `process.waitUntilExit()` with no deadline.
// Reason: `waitUntilExit()` with no timeout can hang indefinitely if a child
// process ignores SIGTERM or holds an open pipe. This pattern was the root
// cause of the main-thread hang tracked in bug #477. The `DispatchWorkItem`
// approach guarantees termination within `timeout` seconds even in that case.
// Do NOT remove the timeout guard.
//
// ## ⚠️ Pipe-drain concurrency — do NOT move readDataToEndOfFile after waitUntilExit
// The stdout pipe must be drained on a background thread *while*
// `waitUntilExit()` blocks. Deferring the drain until after exit lets the
// kernel pipe buffer (~64 KB on macOS) fill up, causing the child process to
// block on a write and `waitUntilExit()` to spin forever (Apple QA1858).
// `launchctl list` on a loaded Mac easily exceeds 64 KB.
//
// `run` drains stdout into a plain `var` inside a `DispatchQueue.async` block
// and reads it back after `drainQueue.sync {}` — the queue provides the
// happens-before guarantee with zero unsafe annotations.
//
// ## Async variant (`runAsync`)
// `runAsync` owns its own `Process` instance and bridges completion via
// `terminationHandler` + `withCheckedContinuation` — no thread is held while
// the subprocess runs. `withTaskCancellationHandler` wires `task.terminate()`
// directly to Swift structured concurrency cancellation. A sibling
// `Task.detached` replaces the `DispatchWorkItem` timeout from `run(_:)`.
//
// Migration (#1365): `Box<T>: @unchecked Sendable` replaced throughout with
// `OSAllocatedUnfairLock`. The lock is a `let` constant captured by `@Sendable`
// closures; `withLock` provides compiler-verified `Sendable` conformance with
// the same queue-serialised happens-before semantics.

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

        // Write stdin after launch so the process is already running and consuming
        // bytes from the read end. This prevents deadlock when stdinData exceeds
        // the kernel pipe buffer (~64 KB): the child drains concurrently as we write.
        if let inputPipe, let stdinData = stdin {
            inputPipe.fileHandleForWriting.write(stdinData)
            inputPipe.fileHandleForWriting.closeFile()
        }

        // Drain stdout on a dedicated queue concurrently with waitUntilExit().
        // See class-level doc: draining must overlap with waitUntilExit() to
        // prevent the kernel pipe buffer (~64 KB) from filling and deadlocking.
        //
        // OSAllocatedUnfairLock is the Swift 6.2-blessed mutable handoff cell:
        // it is Sendable, requires no @unchecked annotation, and the lock is
        // held only for the brief assignment/read — never across a suspension.
        // `drainQueue.sync {}` after `waitUntilExit()` provides the happens-before
        // guarantee: the write inside withLock is always complete before we read it.
        let outputBox = OSAllocatedUnfairLock(initialState: Data())
        let drainQueue = DispatchQueue(label: "ProcessRunner.drain")
        drainQueue.async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            outputBox.withLock { $0 = data }
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
        // writing into outputBox. After this sync barrier the stored Data is safe to
        // read on the calling thread; queue serialisation is the happens-before edge.
        // (The OSAllocatedUnfairLock on outputBox satisfies Sendable — the actual
        // mutual-exclusion guarantee here comes from drainQueue.sync, not the lock.)
        drainQueue.sync {}

        let exitCode = task.terminationStatus
        let outputData = outputBox.withLock { $0 }
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
    /// process execution, mirroring the `Box + drainQueue.sync` pattern in `run(_:)`
    /// `readDataToEndOfFile()` blocks until the pipe's write end closes (i.e. the
    /// process exits), so all bytes are captured in a single call with one clear
    /// happens-before edge. `terminationHandler` joins the drain queue with
    /// `drainQueue.sync {}` before reading the result — no actor, no lock, no
    /// fire-and-forget tasks required.
    ///
    /// ## stdin ordering
    /// When `stdin` data is provided, it is written on a dedicated serial
    /// `stdinQueue` that is dispatched *after* `drainQueue.async` and *after*
    /// `task.run()`. The ordering guarantee is:
    ///
    /// 1. `drainQueue.async { readDataToEndOfFile }` — drain starts, blocks until
    ///    the write end of stdout closes (i.e. the child exits).
    /// 2. `task.run()` — child process launches and begins consuming stdin.
    /// 3. `stdinQueue.async { [inputPipe] write + closeFile }` — stdin bytes are fed
    ///    to the child concurrently as it runs. `closeFile()` signals EOF once all
    ///    bytes have been written. The child may exit before or after the write
    ///    completes; either way `drainQueue.sync {}` in `terminationHandler` joins
    ///    stdout first.
    ///
    /// ⚠️ **SIGPIPE / crash risk for future callers:** `FileHandle.write(_:)` is
    /// non-throwing. On macOS 10.15.4+, if the child process exits before consuming
    /// all stdin, the OS delivers `SIGPIPE` to the writing thread, which **crashes**
    /// the process rather than throwing an error. This is safe for callers like
    /// `/bin/cat` that always consume their full input, but future callers whose
    /// child may exit early should use a `writeabilityHandler`-based writer that
    /// can detect and handle a broken pipe without crashing.
    ///
    /// This approach:
    /// - Does **not** block a cooperative thread pool worker (no synchronous write
    ///   before `task.run()`, fixing the pre-launch deadlock for payloads > ~64 KB).
    /// - Does **not** race against `terminationHandler` (fixes #1077/#1228): `stdinQueue`
    ///   is a separate serial queue from `drainQueue`; the drain joins its own queue
    ///   via `drainQueue.sync {}` without depending on stdin completion.
    /// - Handles arbitrarily large stdin payloads — the child drains the pipe
    ///   concurrently as `stdinQueue` feeds bytes in.
    ///
    /// ## ⚠️ Do NOT add DispatchGroup.wait() to join stdinQueue in terminationHandler
    /// This has been suggested by automated reviewers. It is the wrong approach for
    /// two reasons:
    ///
    /// 1. **Modernisation mandate (#1220):** This file is part of a migration away from
    ///    GCD-era primitives toward Swift structured concurrency. Adding a
    ///    `DispatchGroup.wait()` inside a `DispatchQueue` callback would introduce
    ///    *more* nested GCD synchronisation — the exact anti-pattern being eliminated.
    ///
    /// 2. **It is unnecessary:** `terminationHandler` fires only after the child process
    ///    has exited. A process cannot exit while its stdin pipe write-end is open and
    ///    actively blocking — by the time `terminationHandler` is called, `stdinQueue`
    ///    has either completed the write or the pipe's broken-pipe signal has already
    ///    been handled by the OS. The only invariant that *must* hold before resuming
    ///    the continuation is that stdout is fully captured — which `drainQueue.sync {}`
    ///    already guarantees.
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
        let outputBox = OSAllocatedUnfairLock(initialState: Data())
        let drainQueue = DispatchQueue(label: "ProcessRunner.drain.async")

        // Dedicated serial queue for stdin writes. Dispatched after task.run() so the
        // child is already running and consuming the read end of inputPipe. This prevents
        // the pre-launch deadlock for payloads > kernel pipe buffer (~64 KB) that the
        // previous synchronous-write approach introduced. See doc comment above.
        //
        // UUID suffix: each runAsync call gets a uniquely labelled queue so that
        // concurrent invocations are distinguishable in Instruments and lldb thread list.
        let stdinQueue: DispatchQueue? = (inputPipe != nil)
            ? DispatchQueue(label: "ProcessRunner.stdin.async.\(UUID().uuidString)")
            : nil

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                drainQueue.async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    outputBox.withLock { $0 = data }
                }

                // Timeout guard — terminates the process if it outlives `timeout`.
                // OSAllocatedUnfairLock is used so terminationHandler (a @Sendable closure)
                // can capture a reference type (let) rather than a var, satisfying Swift 6.2
                // strict concurrency. The lock is held only for the brief assignment/read.
                // The box is written once after task.run() and read once inside
                // terminationHandler — both on the same serialised execution path (#1152).
                let timeoutTaskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

                task.terminationHandler = { t in
                    let exitCode = t.terminationStatus
                    // Cancel the timeout guard immediately — process has already exited.
                    timeoutTaskBox.withLock { $0 }?.cancel()
                    // Join the drain queue: blocks until readDataToEndOfFile() finishes.
                    // This is the happens-before guarantee that makes outputBox safe
                    // to read immediately after. The drainQueue.sync call is cheap here
                    // because the process has already exited and the pipe is closed.
                    //
                    // We do NOT sync on stdinQueue here — see the ⚠️ doc comment on
                    // runAsync() above for the full rationale. Short version: it is
                    // unnecessary (terminationHandler fires after exit, by which point
                    // stdin has completed or been broken-piped), and adding a
                    // DispatchGroup.wait() here would be a step backwards for the #1220
                    // modernisation effort.
                    drainQueue.sync {}
                    let outputData = outputBox.withLock { $0 }
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
                    // Close both pipe write-ends so that any already-dispatched drain
                    // block receives EOF and returns cleanly. outPipe must be closed to
                    // unblock the drainQueue.async readDataToEndOfFile() call above.
                    // inputPipe is closed explicitly here (mirrors outPipe) even though
                    // ARC would close it on dealloc — being explicit documents intent
                    // and avoids leaving a half-open pipe handle until the next ARC cycle.
                    outPipe.fileHandleForWriting.closeFile()
                    inputPipe?.fileHandleForWriting.closeFile()
                    continuation.resume(returning: Result(data: nil, exitCode: Int32.max))
                    return
                }

                // Dispatch stdin write after task.run() — the child is now running and
                // will consume bytes from the read end concurrently. This is safe for
                // arbitrarily large payloads: the child drains the pipe buffer as we fill
                // it. closeFile() signals EOF to the child once all bytes are written.
                //
                // Explicit [inputPipe] capture: inputPipe is a Pipe reference retained
                // by this closure until stdinQueue drains. The capture list makes the
                // lifetime management visible rather than implicit.
                if let stdinQueue, let inputPipe, let stdinData = stdin {
                    stdinQueue.async { [inputPipe] in
                        inputPipe.fileHandleForWriting.write(stdinData)
                        inputPipe.fileHandleForWriting.closeFile()
                    }
                }

                // Create the Task *before* acquiring the lock so it is already
                // scheduled by the time timeoutTaskBox is written. terminationHandler
                // reads timeoutTaskBox only after the process exits, which is always
                // after this write completes — the serialised continuation path
                // provides the happens-before edge (#1152).
                let timeoutTask = Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        guard task.isRunning else { return }
                        log("ProcessRunner › timeout (\(timeout)s) — terminating \(executableURL.lastPathComponent)")
                        task.terminate()
                    } catch {
                        // CancellationError from timeoutTask.cancel() — process already done.
                    }
                }
                timeoutTaskBox.withLock { $0 = timeoutTask }
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
