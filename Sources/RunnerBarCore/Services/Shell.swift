// Shell.swift
// RunnerBar
// swiftlint:disable function_body_length
import Foundation

// MARK: - Filesystem path constants
/// The zshBinaryPath constant.
private let zshBinaryPath = "/bin/zsh"

// Executes shell commands synchronously.
/// Enumerates possible values for Shell.
@available(*, deprecated, message: "Use ProcessRunner.run(_:arguments:timeout:) instead. Shell.run uses /bin/zsh -c which carries shell-injection risk and /bin/zsh startup overhead.")
public enum Shell {

    /// The output and exit code produced by a shell command execution.
    struct Result {
        /// The output constant.
        let output: String
        /// The exitCode constant.
        let exitCode: Int32
    }

    /// Runs `command` in `/bin/zsh -c` and returns the trimmed stdout + exit code.
    ///
    /// Timeout is enforced via a `DispatchSemaphore`; if the process does not exit
    /// within `timeout` seconds it is terminated and an empty result is returned.
    ///
    /// ⚠️ NEVER call `process.waitUntilExit()` directly here — it has no deadline and
    /// will block the calling thread forever if the subprocess hangs (e.g. `ps aux` on
    /// a zombie process, or zsh startup loading a slow `.zshrc`).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    ///
    /// - Parameters:
    ///   - command: The shell command string to execute via `/bin/zsh -c`.
    ///   - timeout: Maximum seconds to wait before terminating the process. Defaults to `20`.
    /// - Returns: A ``Result`` containing trimmed stdout and the process exit code (`-1` on timeout or launch failure).
    @discardableResult
    static func run(_ command: String, timeout: TimeInterval = 20) -> Result {
        log("Shell.run › ENTER command=\(command) timeout=\(timeout)s thread=\(Thread.current)")
        let process = makeProcess(command)
        let (outPipe, errPipe) = attachPipes(to: process)
        do { try process.run() } catch {
            log("Shell.run › LAUNCH FAILED command=\(command) error=\(error.localizedDescription)")
            return Result(output: error.localizedDescription, exitCode: -1)
        }
        log("Shell.run › launched pid=\(process.processIdentifier) command=\(command) — waiting up to \(timeout)s")
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            log("Shell.run › process exited pid=\(process.processIdentifier) status=\(process.terminationStatus) command=\(command)")
            sema.signal()
        }
        let waitResult = sema.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            log("Shell.run › ⏰ TIMEOUT after \(timeout)s — terminating pid=\(process.processIdentifier) command=\(command)")
            process.terminate()
            _ = errPipe
            return Result(output: "", exitCode: -1)
        }
        let output = readOutput(from: outPipe)
        _ = errPipe
        log("Shell.run › EXIT command=\(command) status=\(process.terminationStatus) outputBytes=\(output.count)")
        return Result(output: output, exitCode: process.terminationStatus)
    }

    /// Creates a `Process` configured to run `command` via `/bin/zsh -c`.
    /// - Parameter command: The shell command string.
    /// - Returns: A configured but not yet launched `Process`.
    private static func makeProcess(_ command: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zshBinaryPath)
        p.arguments = ["-c", command]
        return p
    }

    /// Attaches stdout and stderr `Pipe`s to `process` and returns them.
    /// - Parameter process: The `Process` to attach pipes to.
    /// - Returns: A tuple of `(stdout pipe, stderr pipe)`.
    private static func attachPipes(to process: Process) -> (Pipe, Pipe) {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        return (out, err)
    }

    /// Reads all available data from `pipe`'s read handle and returns it as a trimmed UTF-8 string.
    /// - Parameter pipe: The `Pipe` whose stdout data should be read.
    /// - Returns: Trimmed UTF-8 string from the pipe, or an empty string if decoding fails.
    private static func readOutput(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
// swiftlint:enable function_body_length

/// Backward-compatibility shim — **deprecated**. Use `ProcessRunner.run` instead.
///
/// This shim delegates to `Shell.run` which wraps `/bin/zsh -c`. It carries
/// shell-injection risk and `/bin/zsh` startup overhead. All call sites have been
/// migrated to `ProcessRunner.run`; this function is retained only to satisfy any
/// remaining compile-time references during the transition period and will be deleted
/// in a follow-up cleanup.
///
/// ⚠️ NEVER ignore the `timeout` parameter here again — that was the bug (ref #477).
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE.
///
/// - Parameters:
///   - command: The shell command string to execute via `/bin/zsh -c`.
///   - timeout: Maximum seconds to wait. Defaults to `20`.
/// - Returns: Trimmed stdout string, or empty on timeout/failure.
@available(*, deprecated, message: "Use ProcessRunner.run(_:arguments:timeout:) instead. This shim uses /bin/zsh -c which carries shell-injection risk.")
@discardableResult
public func shell(_ command: String, timeout: TimeInterval = 20) -> String {
    log("shell() shim › command=\(command) timeout=\(timeout)")
    let result = Shell.run(command, timeout: timeout).output
    log("shell() shim › returned \(result.count)b for command=\(command)")
    return result
}
