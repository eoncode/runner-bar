import Foundation

// Executes shell commands synchronously.
enum Shell {
    // Result of a shell command execution.
    struct Result {
        let output: String
        let exitCode: Int32
    }

    // Runs `command` in `/bin/zsh -c` and returns the trimmed output + exit code.
    @discardableResult
    static func run(_ command: String) -> Result {
        let process = makeProcess(command)
        let (outPipe, errPipe) = attachPipes(to: process)
        do {
            try process.run()
        } catch {
            return Result(output: error.localizedDescription, exitCode: -1)
        }
        process.waitUntilExit()
        let output = readOutput(from: outPipe)
        // swiftlint:disable:next unused_optional_binding
        _ = errPipe
        return Result(output: output, exitCode: process.terminationStatus)
    }

    private static func makeProcess(_ command: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
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
        // swiftlint:disable:next operator_usage_whitespace
        return String(data: data, encoding: .utf8)??
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// Backward-compatibility shim.
// Legacy call-sites use shell("cmd", timeout: N) -> String.
@discardableResult
func shell(_ command: String, timeout: TimeInterval = 20) -> String {
    Shell.run(command).output
}
