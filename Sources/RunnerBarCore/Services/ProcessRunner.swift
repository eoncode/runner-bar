// ProcessRunner.swift
// RunnerBarCore
import Foundation
import os

// MARK: - ProcessRunner

// Shared primitive for launching subprocesses with streaming output,
// optional stdin, optional working directory, and structured-concurrency timeout handling.
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
// ## Async variant (`runAsync`)
// `runAsync` owns its own `Process` instance and bridges completion via
// `terminationHandler` + `withCheckedContinuation` — no thread is held while
// the subprocess runs. `withTaskCancellationHandler` wires `task.terminate()`
// directly to Swift structured concurrency cancellation, and a sibling
// `Task.detached` uses `Task.sleep(for:)` to enforce the timeout without
// GCD-managed timer state.
//
// Migration (#1365/#1366): the legacy synchronous `run()` path was removed.
// `OSAllocatedUnfairLock` replaces `Box<T>: @unchecked Sendable` throughout;
// the lock is a `let` constant captured by `@Sendable` closures — `withLock`
// provides compiler-verified `Sendable` conformance with the same
// queue-serialised happens-before semantics.

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

    // MARK: - Async

    /// Launches an executable asynchronously without blocking the cooperative thread pool.
    ///
    /// This method owns its `Process` instance directly so that Swift structured
    /// concurrency can interact with it properly:
    ///
    /// - **Suspension:** the caller suspends at the `await` and is resumed by
    ///   `terminationHandler` when the process exits — no thread is held.
    /// - **Cancellation:** `withTaskCancellationHandler` calls `task.terminate()`
    ///   the moment the enclosing `Task` is cancelled (e.g. when `start()` replaces
    ///   `pollTask`), bounding latency to OS signal-delivery time rather than the
    ///   full `timeout`.
    /// - **Timeout:** a sibling `Task.detached` sleeps for `timeout` seconds and
    ///   then calls `task.terminate()` if the process is still running, preserving
    ///   hang-safety without a `DispatchWorkItem`. The timeout task is intentionally
    ///   `Task.detached` — it must outlive the `withCheckedContinuation` scope and
    ///   run regardless of the parent task's cancellation state. Its lifetime is
    ///   bounded by the earlier of: (a) `terminationHandler` cancelling it after
    ///   process exit, or (b) the `timeout` interval elapsing.
    ///
    /// ## ⚠️ Pipe-drain concurrency
    /// stdout is drained via a dedicated serial `DispatchQueue` *concurrently* with
    /// process execution (concurrent drain + `terminationHandler` join pattern).
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
    /// All parameters and defaults are identical to the removed synchronous `run()` method.
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
        // (concurrent drain + terminationHandler join pattern). readDataToEndOfFile() blocks until
        // the write end of the pipe is closed (i.e. the process exits), so it captures
        // all output in one call with a single clear happens-before edge.
        //
        // Using a DispatchQueue here (not a Task) keeps the drain off the cooperative
        // thread pool, avoids the fire-and-forget Task.detached-per-chunk pattern, and
        // ensures drainQueue.sync {} in terminationHandler is the sole synchronisation
        // point. `outputBox` is an `OSAllocatedUnfairLock` for Swift 6 `Sendable`
        // compliance — the lock is held only for the brief Data assignment/read;
        // the queue's `sync {}` barrier, not the lock, is the happens-before edge.
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
                    // Read under lock, cancel outside — avoids holding the unfair lock during Task.cancel().
                    let timeoutTask = timeoutTaskBox.withLock { $0 }
                    timeoutTask?.cancel()
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
                // scheduled by the time timeoutTaskBox is written.
                //
                // Two benign races exist here:
                //
                // 1. Fast-exit: terminationHandler fires before timeoutTaskBox is
                //    written — it reads nil and skips .cancel(). The timeout task
                //    then fires later but finds task.isRunning == false and exits
                //    without calling terminate(). Safe.
                //
                // 2. Slow-exit: the process outlives the timeout, terminate() is
                //    called by the timeout task, then terminationHandler fires and
                //    reads timeoutTaskBox — but by then the timeout task has already
                //    finished (it returned after terminate()), so .cancel() is a
                //    benign no-op on a completed Task. Safe.
                //
                // In both cases guard task.isRunning is the invariant that prevents
                // a double-terminate. This race existed in the pre-refactor Box<T>
                // code as well (#1152).
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
