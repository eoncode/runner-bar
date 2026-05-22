// swiftlint:disable function_body_length
import Foundation

// MARK: - Filesystem path constants
private let zshBinaryPath = "/bin/zsh"

// Executes shell commands synchronously.
enum Shell {

    // Result of a shell command execution.
    struct Result {
        let output: String
        let exitCode: Int32
    }

    // Runs `command` in `/bin/zsh -c` and returns the trimmed output + exit code.
    // `timeout` is enforced via a DispatchSemaphore — if the process does not exit
    // within `timeout` seconds it is terminated and an empty result is returned.
    // ⚠️ NEVER call process.waitUntilExit() directly here — it has no deadline and
    // will block the calling thread forever if the subprocess hangs (e.g. ps aux on
    // a zombie process, or zsh startup loading a slow .zshrc).
    // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE.
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

    private static func makeProcess(_ command: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zshBinaryPath)
        p.arguments = ["-c", command]
        return p
    }

    private static func attachPipes(to process: Process) -> (Pipe, Pipe) {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        return (out, err)
    }

    private static func readOutput(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
// swiftlint:enable function_body_length

// Backward-compatibility shim.
// timeout is now forwarded to Shell.run which enforces it via DispatchSemaphore.
// ⚠️ NEVER ignore the timeout parameter here again — that was the bug (ref #477).
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE.
@discardableResult
func shell(_ command: String, timeout: TimeInterval = 20) -> String {
    log("shell() shim › command=\(command) timeout=\(timeout)")
    let result = Shell.run(command, timeout: timeout).output
    log("shell() shim › returned \(result.count)b for command=\(command)")
    return result
}
